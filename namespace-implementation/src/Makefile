# Makefile for namespace-based microservice
# Builds a statically-linked binary for portability across namespaces

CC = gcc
CFLAGS = -Wall -Wextra -O2
LDFLAGS = -static
TARGET = service
SRC = service.c

.PHONY: all clean

all: $(TARGET)

$(TARGET): $(SRC)
	$(CC) $(CFLAGS) $(LDFLAGS) -o $(TARGET) $(SRC)

clean:
	rm -f $(TARGET)
