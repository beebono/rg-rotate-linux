/* Minimal tinymix: list controls, read one, or set one by name.
 *   tmix                 -> list all controls (numid, type, count, name)
 *   tmix "Name"          -> read current value(s) + range
 *   tmix "Name" v [v...] -> write integer/enum/bool values to the control
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sound/asound.h>

int main(int argc, char **argv) {
	int fd = open("/dev/snd/controlC0", O_RDWR);
	if (fd < 0) { perror("open ctl"); return 1; }

	struct snd_ctl_elem_list list = {0};
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list)) { perror("LIST"); return 2; }
	unsigned count = list.count;
	struct snd_ctl_elem_id *ids = calloc(count, sizeof(*ids));
	list.space = count; list.pids = ids;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_LIST, &list)) { perror("LIST2"); return 2; }

	if (argc == 1) {
		for (unsigned i = 0; i < list.used; i++) {
			struct snd_ctl_elem_info info = {0};
			info.id = ids[i];
			if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info)) continue;
			printf("#%u\t[t%d c%u]\t%s\n", ids[i].numid, info.type,
			       info.count, ids[i].name);
		}
		return 0;
	}

	/* set by name */
	const char *name = argv[1];
	struct snd_ctl_elem_id *id = NULL;
	for (unsigned i = 0; i < list.used; i++)
		if (!strcmp((char *)ids[i].name, name)) { id = &ids[i]; break; }
	if (!id) { fprintf(stderr, "control '%s' not found\n", name); return 3; }

	struct snd_ctl_elem_info info = {0};
	info.id = *id;
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_INFO, &info)) { perror("INFO"); return 4; }

	struct snd_ctl_elem_value val = {0};
	val.id = *id;

	/* read-only: just print the current value(s) and the range */
	if (argc == 2) {
		if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_READ, &val)) { perror("READ"); return 5; }
		printf("'%s' =", name);
		for (int i = 0; i < (int)info.count; i++)
			printf(" %ld", val.value.integer.value[i]);
		printf("  [min %ld max %ld]\n",
		       info.value.integer.min, info.value.integer.max);
		return 0;
	}

	int nv = argc - 2;
	for (int i = 0; i < (int)info.count; i++) {
		long v = atol(argv[2 + (i < nv ? i : nv - 1)]);
		val.value.integer.value[i] = v;
	}
	if (ioctl(fd, SNDRV_CTL_IOCTL_ELEM_WRITE, &val)) { perror("WRITE"); return 5; }
	printf("set '%s' ok\n", name);
	return 0;
}
