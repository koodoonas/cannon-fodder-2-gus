NASM ?= nasm
PYTHON ?= python3

SOURCE := src/cf2gus.asm
BINARY := dist/CF2GUS.COM

.PHONY: all audit check clean test

all: $(BINARY)

$(BINARY): $(SOURCE) | dist
	$(NASM) -Wall -f bin -o $@ $<

dist:
	mkdir -p $@

test:
	$(PYTHON) -m unittest discover -s tests -v

audit:
	$(PYTHON) tools/audit_repository.py .

check: all test audit

clean:
	rm -f $(BINARY)
