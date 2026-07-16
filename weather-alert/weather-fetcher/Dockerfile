# Multi-stage build
FROM golang:1.21-alpine AS builder

WORKDIR /build
COPY weather-fetcher/ ./
RUN go mod tidy && CGO_ENABLED=0 GOOS=linux go build -a -installsuffix cgo -o app cmd/server/main.go

# Final image
FROM alpine:latest
RUN apk --no-cache add ca-certificates
WORKDIR /root/

COPY --from=builder /build/app .

EXPOSE 8002

CMD ["./app"]
