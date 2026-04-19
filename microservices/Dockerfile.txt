FROM golang:1.21 AS builder

WORKDIR /app
COPY server.go .

RUN go mod init app || true
RUN go mod tidy || true
RUN CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -o server server.go

FROM alpine:3.19

WORKDIR /app
COPY --from=builder /app/server .

EXPOSE 8080

CMD ["./server"]