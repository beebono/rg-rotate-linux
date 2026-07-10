/* Minimal raw-ioctl ALSA player: plays a 48k S16_LE stereo sine to hw:0,0
 * to exercise the VBC/AGDSP IPC path. tinyalsa-style hw_params construction. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <sys/ioctl.h>
#include <stdint.h>
#include <limits.h>
#include <errno.h>
#include <time.h>
#include <signal.h>
#include <sound/asound.h>

static volatile sig_atomic_t keep_running = 1;

static void handle_signal(int sig)
{
	(void)sig;
	keep_running = 0;
}

static void dump_status(int fd, const char *tag)
{
	struct snd_pcm_status st;

	memset(&st, 0, sizeof(st));
	if (ioctl(fd, SNDRV_PCM_IOCTL_STATUS, &st) == 0) {
		printf("%s state=%d avail=%lu delay=%ld overrange=%lu\n",
		       tag, st.state, (unsigned long)st.avail,
		       (long)st.delay, (unsigned long)st.overrange);
	} else {
		perror("STATUS");
	}
}

static void mask_set(struct snd_mask *m, unsigned bit) {
	m->bits[bit >> 5] |= (1u << (bit & 31));
}
static void mask_any(struct snd_mask *m) { memset(m, 0xff, sizeof(*m)); }
static void ival_set(struct snd_interval *i, unsigned val) {
	i->min = i->max = val; i->integer = 1; i->openmin = i->openmax = 0;
}
static void ival_any(struct snd_interval *i) {
	i->min = 0; i->max = UINT_MAX; i->integer = 0; i->openmin = i->openmax = 0; i->empty = 0;
}

#define FIRST_MASK SNDRV_PCM_HW_PARAM_ACCESS
#define LAST_MASK  SNDRV_PCM_HW_PARAM_SUBFORMAT
#define FIRST_IVAL SNDRV_PCM_HW_PARAM_SAMPLE_BITS
#define LAST_IVAL  SNDRV_PCM_HW_PARAM_TICK_TIME

static struct snd_mask *pmask(struct snd_pcm_hw_params *p, int n) {
	return &p->masks[n - FIRST_MASK];
}
static struct snd_interval *pival(struct snd_pcm_hw_params *p, int n) {
	return &p->intervals[n - FIRST_IVAL];
}

int main(int argc, char **argv) {
	/* args: freq amplitude period_frames seconds [device] [channels]
	 * [access] [hold]
	 * access: "i" = interleaved (default), "n" = noninterleaved
	 * hold: seconds to keep the PCM open after writing, or "wait" to
	 * hold until Ctrl-C
	 * (period must be x160) */
	int freq   = argc > 1 ? atoi(argv[1]) : 220;
	int amp    = argc > 2 ? atoi(argv[2]) : 6500;
	int period = argc > 3 ? atoi(argv[3]) : 1280;   /* 160*8 -> 5120 bytes */
	int secs   = argc > 4 ? atoi(argv[4]) : 1;
	const char *dev = argc > 5 ? argv[5] : "/dev/snd/pcmC0D0p";
	int chans  = argc > 6 ? atoi(argv[6]) : 2;
	int noninterleaved = argc > 7 && argv[7][0] == 'n';
	int hold_secs = 0;
	int hold_until_sigint = 0;

	if (argc > 8) {
		if (!strcmp(argv[8], "wait")) {
			hold_until_sigint = 1;
		} else {
			hold_secs = atoi(argv[8]);
		}
	}

	signal(SIGINT, handle_signal);
	signal(SIGTERM, handle_signal);

	int fd = open(dev, O_RDWR);
	if (fd < 0) { perror("open"); return 1; }

	struct snd_pcm_hw_params p;
	memset(&p, 0, sizeof(p));
	for (int n = FIRST_MASK; n <= LAST_MASK; n++) mask_any(pmask(&p, n));
	for (int n = FIRST_IVAL; n <= LAST_IVAL; n++) ival_any(pival(&p, n));
	p.rmask = ~0u; p.cmask = 0; p.info = ~0u;

	mask_set(pmask(&p, SNDRV_PCM_HW_PARAM_ACCESS),
		 noninterleaved ? SNDRV_PCM_ACCESS_RW_NONINTERLEAVED :
				  SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	pmask(&p, SNDRV_PCM_HW_PARAM_ACCESS)->bits[0] =
		1u << (noninterleaved ? SNDRV_PCM_ACCESS_RW_NONINTERLEAVED :
				       SNDRV_PCM_ACCESS_RW_INTERLEAVED);
	memset(pmask(&p, SNDRV_PCM_HW_PARAM_ACCESS)->bits+1, 0, sizeof(struct snd_mask)-4);
	pmask(&p, SNDRV_PCM_HW_PARAM_FORMAT)->bits[0] = (1u<<SNDRV_PCM_FORMAT_S16_LE);
	memset(pmask(&p, SNDRV_PCM_HW_PARAM_FORMAT)->bits+1, 0, sizeof(struct snd_mask)-4);
	pmask(&p, SNDRV_PCM_HW_PARAM_SUBFORMAT)->bits[0] = (1u<<SNDRV_PCM_SUBFORMAT_STD);
	memset(pmask(&p, SNDRV_PCM_HW_PARAM_SUBFORMAT)->bits+1, 0, sizeof(struct snd_mask)-4);

	int nper = 8;
	ival_set(pival(&p, SNDRV_PCM_HW_PARAM_CHANNELS), chans);
	ival_set(pival(&p, SNDRV_PCM_HW_PARAM_RATE), 48000);
	ival_set(pival(&p, SNDRV_PCM_HW_PARAM_PERIOD_SIZE), period);
	ival_set(pival(&p, SNDRV_PCM_HW_PARAM_PERIODS), nper);

	if (ioctl(fd, SNDRV_PCM_IOCTL_HW_PARAMS, &p)) {
		perror("HW_PARAMS");
		/* diagnostic: refine a fresh "any" to see accepted ranges */
		struct snd_pcm_hw_params r;
		memset(&r, 0, sizeof(r));
		for (int n = FIRST_MASK; n <= LAST_MASK; n++) mask_any(pmask(&r, n));
		for (int n = FIRST_IVAL; n <= LAST_IVAL; n++) ival_any(pival(&r, n));
		r.rmask = ~0u; r.info = ~0u;
		if (ioctl(fd, SNDRV_PCM_IOCTL_HW_REFINE, &r)) {
			perror("HW_REFINE");
		} else {
			struct snd_interval *rate = pival(&r, SNDRV_PCM_HW_PARAM_RATE);
			struct snd_interval *ch = pival(&r, SNDRV_PCM_HW_PARAM_CHANNELS);
			struct snd_interval *ps = pival(&r, SNDRV_PCM_HW_PARAM_PERIOD_SIZE);
			struct snd_interval *pb = pival(&r, SNDRV_PCM_HW_PARAM_PERIOD_BYTES);
			struct snd_interval *pn = pival(&r, SNDRV_PCM_HW_PARAM_PERIODS);
			struct snd_mask *fmt = pmask(&r, SNDRV_PCM_HW_PARAM_FORMAT);
			printf("REFINE rate[%u-%u] ch[%u-%u] pers[%u-%u] psize[%u-%u] pbytes[%u-%u] fmt0=%#x\n",
			       rate->min, rate->max, ch->min, ch->max, pn->min, pn->max,
			       ps->min, ps->max, pb->min, pb->max, fmt->bits[0]);
		}
		return 2;
	}
	printf("HW_PARAMS ok\n");
	dump_status(fd, "STATUS after HW_PARAMS");

	/* SW params: start only once the WHOLE buffer is queued (full cushion,
	 * so the DSP/MCDT drain has 8 periods to chew on before it can underrun),
	 * and never auto-stop on underrun so a brief XRUN doesn't EPIPE / tear
	 * down the stream at trigger. The kernel ignores our sw.boundary and
	 * recomputes runtime->boundary itself (pcm_native.c), so we don't try to
	 * match it; a large stop_threshold is stored unvalidated and just means
	 * "never auto-stop". avail_min must be non-zero or SW_PARAMS -> EINVAL. */
	unsigned long bufsz = (unsigned long)period * nper;
	struct snd_pcm_sw_params sw;
	memset(&sw, 0, sizeof(sw));
	sw.proto = SNDRV_PCM_VERSION;
	sw.xfer_align = 1;
	sw.tstamp_mode = SNDRV_PCM_TSTAMP_NONE;
	sw.period_step = 1;
	sw.avail_min = period;
	sw.start_threshold = bufsz;          /* auto-start only when buffer full */
	sw.stop_threshold = LONG_MAX;        /* never auto-stop on underrun */
	sw.silence_threshold = 0;
	sw.silence_size = 0;
	sw.boundary = bufsz;                 /* ignored by kernel; kept sane */
	if (ioctl(fd, SNDRV_PCM_IOCTL_SW_PARAMS, &sw)) { perror("SW_PARAMS"); return 3; }
	printf("SW_PARAMS ok (start_thr=%lu stop_thr=LONG_MAX bufsz=%lu)\n",
	       bufsz, bufsz);
	dump_status(fd, "STATUS after SW_PARAMS");

	if (ioctl(fd, SNDRV_PCM_IOCTL_PREPARE)) { perror("PREPARE"); return 3; }
	printf("PREPARE ok\n");
	dump_status(fd, "STATUS after PREPARE");

	/* ~1s low sine: 220Hz, ~20% full-scale (digital). NOTE: actual
	 * loudness also depends on the sc2730 HP + aw87 PA analog gain, which
	 * are at power-on defaults here (no mixer set), so this is best-effort
	 * quiet. */
	/* Loop on a WALL CLOCK for `secs` seconds, continuously re-filling the
	 * ring. If playback is genuinely DAC-paced, WRITEI blocks and we emit
	 * ~secs of audio; if it free-runs, we just keep stuffing the ring and
	 * the stream stays RUNNING the whole time (stop_threshold=LONG_MAX) so
	 * MCDT/DAPM state can be sampled from another shell while this runs. */
	int frames = period;
	int16_t *buf = malloc(frames * chans * sizeof(int16_t));
	int16_t *chan_buf[2] = { NULL, NULL };
	void *bufs[2] = { NULL, NULL };
	if (noninterleaved) {
		for (int c = 0; c < chans && c < 2; c++) {
			chan_buf[c] = malloc(frames * sizeof(int16_t));
			if (!chan_buf[c]) {
				perror("malloc");
				return 5;
			}
			bufs[c] = chan_buf[c];
		}
	}
	time_t end = time(NULL) + secs;
	long w = 0;
	while (time(NULL) < end) {
		if (noninterleaved) {
			for (int i = 0; i < frames; i++) {
				double t = (double)(w*frames + i) / 48000.0;
				int16_t s = (int16_t)((double)amp * sin(2*M_PI*freq*t));
				for (int c = 0; c < chans && c < 2; c++)
					chan_buf[c][i] = s;
			}
			struct snd_xfern xfer = { .bufs = bufs, .frames = frames };
			if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEN_FRAMES, &xfer)) {
				printf("WRITEN err: errno=%d (%s) after %ld periods result=%ld\n",
				       errno, strerror(errno), w, (long)xfer.result);
				dump_status(fd, "STATUS after WRITEN err");
				if (errno == EPIPE) {
					ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
					dump_status(fd, "STATUS after EPIPE PREPARE");
					ioctl(fd, SNDRV_PCM_IOCTL_WRITEN_FRAMES, &xfer);
					continue;
				}
				perror("WRITEN");
				printf("wrote %ld periods before err\n", w);
				return 4;
			}
		} else {
			for (int i = 0; i < frames; i++) {
				double t = (double)(w*frames + i) / 48000.0;
				int16_t s = (int16_t)((double)amp * sin(2*M_PI*freq*t));
				for (int c = 0; c < chans; c++)
					buf[i*chans + c] = s;
			}
			struct snd_xferi xfer = { .buf = buf, .frames = frames, .result = 0 };
			if (ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer)) {
				printf("WRITEI err: errno=%d (%s) after %ld periods result=%ld\n",
				       errno, strerror(errno), w, (long)xfer.result);
				dump_status(fd, "STATUS after WRITEI err");
				if (errno == EPIPE) {        /* XRUN: recover and continue */
					ioctl(fd, SNDRV_PCM_IOCTL_PREPARE);
					dump_status(fd, "STATUS after EPIPE PREPARE");
					ioctl(fd, SNDRV_PCM_IOCTL_WRITEI_FRAMES, &xfer);
					continue;
				}
				perror("WRITEI");
				printf("wrote %ld periods before err\n", w);
				return 4;
			}
		}
		w++;
	}
	if (hold_until_sigint) {
		printf("HOLDING stream open; press Ctrl-C when register capture is done\n");
		while (keep_running)
			sleep(1);
	} else if (hold_secs > 0) {
		printf("HOLDING stream open for %d more second(s)\n", hold_secs);
		sleep(hold_secs);
	}

	ioctl(fd, SNDRV_PCM_IOCTL_DRAIN);
	printf("HELD %ds, wrote %ld periods (%.1f s of audio)\n",
	       secs, w, (double)w * frames / 48000.0);
	close(fd);
	return 0;
}
