FROM golang:1.21

WORKDIR /app

COPY server.go .

RUN go build -o server server.go

CMD ["./server"]
