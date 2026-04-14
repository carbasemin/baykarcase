# Baykar Case

Baykar MERN uygulamasının (ve en altta Python cron'u) tercih ettiğim yöntemlerle, yine tercih ettiğim bulut üzerinde deploy edilmesi. Mern uygulaması ekran görüntüleri [screenshots](/screenshots/) klasöründe.

## Mimari Genel Bakış

Altyapı; modülerlik ve güvenlik ön planda tutularak, olabildiğince basit düşünerek ve uygulanarak kuruldu:

* **Bulut Sağlayıcı:** AWS
* **Orkestrasyon:** EKS (v1.35)
* **Gateway:** ALB
* **Container Registry:** ECR
* **Veritabanı:** MongoDB Atlas
* **Trafik Yönlendirme / DNS:** Cloudflare
* **IaC ve Paketleme:** Terraform, Helm
* **CI/CD:** GitHub Actions

## CI (Build & Push)

* **Anahtarsız Kimlik Doğrulama:** AWS OIDC. Statik Service Account key kullanımını doğru bulmuyorum. Projeyi olabildiğince basite indirgemiş olsam da bu konuda taviz vermek istemedim. Terraform apply'dan sonra, output'lardaki `AWS_ROLE_ARN` GitHub Actions'a secret olarak eklenmeli.
* **Image Build:** Frontend için statik dosyaları build edip Nginx ile sunuyorum. Backend için de build sonrası distroless (Google) imaj kullandım. Atak yüzeyini minimuma indirmek için. Build edilen imajlar ECR'a gönderiliyor.
* **Layer Cache:** Docker Buildx + GitHub cache

Bu case için sadece `main` branch'i varmış ve oraya push yapılıyormuş gibi davrandım. Deploy ederken de tek bir cluster'a deploy ettim. Normalde farklı ortamlar, farklı ortamlara ait farklı branchler, PR'lar, versiyonlanmış imajlar vs. de olacak elbette. Kurduğum kemik yapı üzerinden çoğaltmak trivial.

Gitleaks ile local check yapıyorum, repoya pre-commit olarak eklenirse güzel olur. Maintain ettiğim repolara eklemeyi tercih ediyorum. ![gitleaks](/screenshots/gitleaks.png)

## Deployment

### Altyapı Kurulumu

3 Terraform klasörümüz var:

* `infra/terraform/ci/`: ECR repository’leri ve GitHub OIDC provider oluşturur
* `infra/terraform/secrets/`: AWS Secrets Manager ile güvenli parametre saklama
* `infra/terraform/eks/`:

  * NAT Gateway’li VPC
  * Cost optimizasyonu için Spot instance kullanan EKS cluster
  * IRSA ("IAM Roles for Service Accounts"). k8s servis account'larının AWS resource'larına erişmesi için

---

### Cluster Add-ons

Uygulamayı deploy etmeden önce cluster’a bazı temel controller’ların kurulması gerek:

* ALB Controller
* External Secrets Operator (ESO). AWS Secrets Manager'daki Mongo Atlas credential'ını backend'in kullanabilmesi için.

(ALB controller için ServiceAccount ve IRSA mapping’in manuel yapılması gerekiyor.)

---

### Uygulama Deployment

`helm/mern-project/`: Frontend ve Backend'i aynı Chart içinde deploy ediyorum, basitleştirmek adına; masraf açısından da tek Ingress kullandım, aynı Chart altında güzel toparlandılar.

---

### Monitoring Stack

* **Prometheus:** Metrik toplama
* **Grafana:** Dashboard ve görselleştirme
* **Fluentd:** Log toplama (DaemonSet)
* **Loki:** Log aggregation - görselleştirme/arama Grafana'dan.

Basit projelerde Loki kullanmayı yeterli görüyorum. Daha ciddi projelerde ELK, uzun süreli metrik tutmak için de Thanos kullanılabilir.
Bütün erişimler port-forward ile, Prometheus ve Grafana'yı dışarı açmadım.

**Tanımlı alarmlar:**

Metriklerden:

* PodCrashLooping → Pod sürekli restart ediyor
* NoBackendPods → Backend pod yok
* HTTPErrorsHigh → %5’ten fazla 5xx hatası

Loglardan:

* MongoDBConnectionError → Bağlantı hataları
* MongoDBServerSelectionError → Server seçim hataları
* MongoDBAuthenticationError → Auth hataları
* MongoDBTLSErrors → TLS/SSL hataları

MongoDB Atlas tarafında ayrıca disk, CPU ve memory için kendi alert sistemi aktif. Managed DB'nin monitoring'i de managed.

---

## Karşılaşılan Problemler

### Ingress Rewrite vs ALB Controller

**Problem:**
Nginx Ingress (geçenlerde deprecate etmeye karar verdiler maalesef), `rewrite-target` ile `/api/record` → `/record` gibi yönlendirme yapabiliyor.
AWS ALB ise path rewrite desteklemiyor.

**Çözüm:**
Express backend (`server.mjs`) `/api` prefix’ini doğrudan dinleyecek şekilde güncelledim. Koda dokunmak istemedim ama çok basit çözecekti, dokundum.

---

### Zincirleme Hata: ALB Webhook & ServiceAccount Uyumsuzluğu

**Problem:**

* Terraform IAM rolü oluşturdu ama ServiceAccount oluşturmadı
* ALB pod'ları ayağa kalkamadı
* Buna rağmen webhook Kubernetes API'ye kayıt oldu
* External Secrets kurulumu sırasında webhook'a erişilemediği için Helm timeout verdi

**Çözüm:**

1. Helm ile ALB controller tekrar kuruldu (`serviceAccount.create=true`)
2. IAM role ARN annotation ile bağlandı
3. Takılan ReplicaSet'ler silindi
4. Yeni pod'lar düzgün şekilde ayağa kalktı
5. Webhook hazır olduktan sonra External Secrets sorunsuz kuruldu

---

### Cloudflare HTTPS Timeout (Error 522)

**Problem:**
Uygulama `https://` üzerinden açılırken timeout veriyor.

**Sebep:**
Daha önceki işlerimden dolayı Cloudflare SSL modu "Full/Strict" idi, CF tarafı ALB'ye HTTPS ile bağlanmaya çalıştı o yüzden.

**Çözüm:**
Cloudflare SSL modunu "Flexible" yaptım. Client istek atarken TLS kullanıyor, Cloudflare ALB'ye attığı istekte TLS kullanmıyor. üvenlik açısından Flexible zayıf kalır. ALB’ye AWS ACM ile sertifika bağlamak production’da daha doğru olur. AWS'ten sertifika talep edip ALB'ye takmak yerine yine basitleştirdim.

---

## Python ETL CronJob

Python tarafında basit bir ETL script'i var, her saat çalışacak şekilde CronJob olarak deploy edildi.

* **İmaj:** Python 3.12 slim
* **Namespace:** `python-etl`
* **Schedule:** Her saat başı (`0 * * * *`)
* **CI:** Ana CI'den ayrı, kendi workflow'u var (`python-project/.github/workflows/ci.yml`)

**Alarmlar:**

* CronJobFailed → CronJob hatası
* CronJobNotRunning → Son 1 saatte çalışmadı
