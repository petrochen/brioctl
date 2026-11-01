CFLAGS ?= -Wall -Wextra -Wno-missing-field-initializers -O2
LDLIBS = -framework IOKit -framework CoreFoundation

all: hidmon uvcwatch

hidmon: hidmon.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

uvcwatch: uvcwatch.c
	$(CC) $(CFLAGS) -o $@ $< $(LDLIBS)

clean:
	rm -f hidmon uvcwatch

.PHONY: all clean
