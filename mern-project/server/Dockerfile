FROM node:18 AS build

WORKDIR /app
COPY package*.json ./
RUN npm ci --only=production
COPY . .

FROM gcr.io/distroless/nodejs18-debian11

WORKDIR /app
# Copy only the app from the build stage
COPY --from=build /app /app

EXPOSE 5050
CMD ["server.mjs"]
