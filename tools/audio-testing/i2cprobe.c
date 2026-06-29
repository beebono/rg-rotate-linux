/* Minimal i2c register probe via /dev/i2c-N using I2C_RDWR.
 *   i2cprobe <bus> <addr> dump [n]      - read regs 0..n-1 (default 16)
 *   i2cprobe <bus> <addr> r <reg>       - read one reg
 *   i2cprobe <bus> <addr> w <reg> <val> - write one reg
 * addr/reg/val are hex (0x..) or dec. */
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <linux/i2c.h>
#include <linux/i2c-dev.h>
#include <sys/ioctl.h>

static int rd(int fd, int addr, unsigned char reg, unsigned char *out) {
	struct i2c_msg msgs[2] = {
		{ .addr = addr, .flags = 0,        .len = 1, .buf = &reg },
		{ .addr = addr, .flags = I2C_M_RD, .len = 1, .buf = out },
	};
	struct i2c_rdwr_ioctl_data x = { .msgs = msgs, .nmsgs = 2 };
	return ioctl(fd, I2C_RDWR, &x);
}
static int wr(int fd, int addr, unsigned char reg, unsigned char val) {
	unsigned char b[2] = { reg, val };
	struct i2c_msg m = { .addr = addr, .flags = 0, .len = 2, .buf = b };
	struct i2c_rdwr_ioctl_data x = { .msgs = &m, .nmsgs = 1 };
	return ioctl(fd, I2C_RDWR, &x);
}

int main(int argc, char **argv) {
	if (argc < 4) { fprintf(stderr, "usage: %s bus addr dump|r|w ...\n", argv[0]); return 1; }
	char path[32]; snprintf(path, sizeof path, "/dev/i2c-%d", atoi(argv[1]));
	int addr = strtol(argv[2], 0, 0);
	int fd = open(path, O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	if (!strcmp(argv[3], "dump")) {
		int n = argc > 4 ? strtol(argv[4],0,0) : 16;
		for (int i = 0; i < n; i++) {
			unsigned char v = 0;
			if (rd(fd, addr, i, &v) < 0) printf("reg%02x = ERR(%s)\n", i, strerror(errno));
			else printf("reg%02x = 0x%02x\n", i, v);
		}
	} else if (!strcmp(argv[3], "r") && argc > 4) {
		unsigned char v = 0;
		if (rd(fd, addr, strtol(argv[4],0,0), &v) < 0) { perror("read"); return 2; }
		printf("0x%02x\n", v);
	} else if (!strcmp(argv[3], "w") && argc > 5) {
		if (wr(fd, addr, strtol(argv[4],0,0), strtol(argv[5],0,0)) < 0) { perror("write"); return 2; }
		printf("ok\n");
	} else { fprintf(stderr, "bad args\n"); return 1; }
	return 0;
}
