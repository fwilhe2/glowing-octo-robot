/*
 * flfsfetch - the summary neofetch prints, for a system that will never have neofetch.
 *
 * Everything here comes from uname(2), the environment, /proc and /sys. There is no
 * dependency beyond glibc, which is the point twice over: nothing has to be packaged to
 * make it build, and test/check-rootfs-deps.sh has nothing to report about the result.
 *
 * Two constraints from the image it ships in shape the output:
 *
 *   - ASCII only. image/build-rootfs.sh deletes share/locale and share/i18n, so the
 *     image is C-locale only and a box-drawing character would print as garbage.
 *   - Every source is optional. A field whose file is missing is left out rather than
 *     printed empty, because which files exist depends on the kernel fragment and the
 *     architecture: /sys/class/dmi wants CONFIG_DMI_SYSFS, /proc/device-tree only
 *     exists where there is a device tree, and /proc/cpuinfo names the CPU on x86 but
 *     not on arm64.
 */
#include <pwd.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <sys/statvfs.h>
#include <sys/utsname.h>
#include <unistd.h>

#define VAL_MAX  192
#define KEY_MAX  16
#define MAX_INFO 24

/* Set from main() once, so every printf below can stay unconditional. */
static const char *c_logo = "";
static const char *c_key = "";
static const char *c_off = "";

static const char *logo[] = {
	"   .-----------.",
	"   | .-------. |",
	"   | | o   o | |",
	"   | |   _   | |",
	"   | '-------' |",
	"   '--+-----+--'",
	"  .---'-----'---.",
	"  |  [  FLFS  ] |",
	"  |  o   o   o  |",
	"  '-------------'",
	"     |||   |||",
};
#define LOGO_LINES ((int)(sizeof logo / sizeof logo[0]))

static struct {
	char key[KEY_MAX];
	char val[VAL_MAX];
} info[MAX_INFO];
static int info_n;

/* A key of "" prints the value alone, which is what the header and the separator want. */
static void add(const char *key, const char *fmt, ...)
{
	va_list ap;

	if (info_n >= MAX_INFO)
		return;
	snprintf(info[info_n].key, KEY_MAX, "%s", key);
	va_start(ap, fmt);
	vsnprintf(info[info_n].val, VAL_MAX, fmt, ap);
	va_end(ap);
	info_n++;
}

static void trim(char *s)
{
	size_t n = strlen(s);

	while (n > 0 && (unsigned char)s[n - 1] <= ' ')
		s[--n] = '\0';
	if (s[0] == '\0')
		return;
	size_t lead = strspn(s, " \t");
	if (lead)
		memmove(s, s + lead, strlen(s + lead) + 1);
}

/* First line of a file, trimmed. Zero on success, so callers can chain fallbacks. */
static int read_line(const char *path, char *out, size_t n)
{
	FILE *f = fopen(path, "re");

	if (!f)
		return -1;
	if (!fgets(out, (int)n, f)) {
		fclose(f);
		return -1;
	}
	fclose(f);
	trim(out);
	return out[0] ? 0 : -1;
}

/*
 * Value of `key <sep> value` in a colon-separated table: /proc/meminfo, /proc/cpuinfo.
 * Case-insensitive because the same information is spelled "model name" on x86 and
 * "Model" or "Hardware" elsewhere, and there is no reason to care which.
 */
static int read_keyed(const char *path, const char *key, char *out, size_t n)
{
	char line[512];
	FILE *f = fopen(path, "re");

	if (!f)
		return -1;
	while (fgets(line, sizeof line, f)) {
		char *sep = strchr(line, ':');

		if (!sep)
			continue;
		*sep = '\0';
		trim(line);
		if (strcasecmp(line, key) != 0)
			continue;
		snprintf(out, n, "%s", sep + 1);
		trim(out);
		fclose(f);
		return out[0] ? 0 : -1;
	}
	fclose(f);
	return -1;
}

/* KEY=value or KEY="value" out of an os-release file. */
static int read_osrelease(const char *key, char *out, size_t n)
{
	char line[512];
	FILE *f = fopen("/etc/os-release", "re");
	size_t keylen = strlen(key);

	if (!f)
		return -1;
	while (fgets(line, sizeof line, f)) {
		if (strncmp(line, key, keylen) != 0 || line[keylen] != '=')
			continue;
		char *val = line + keylen + 1;
		trim(val);
		size_t len = strlen(val);
		if (len >= 2 && val[0] == '"' && val[len - 1] == '"') {
			val[len - 1] = '\0';
			val++;
		}
		snprintf(out, n, "%s", val);
		fclose(f);
		return out[0] ? 0 : -1;
	}
	fclose(f);
	return -1;
}

static unsigned long long meminfo_kb(const char *key)
{
	char val[VAL_MAX];

	if (read_keyed("/proc/meminfo", key, val, sizeof val) != 0)
		return 0;
	return strtoull(val, NULL, 10);
}

/* MiB below a gibibyte, GiB above it, so neither a 512 MiB VM nor a 40 GiB disk reads
 * as noise. Kibibytes in, because that is the unit both /proc/meminfo and the block
 * arithmetic below already work in. */
static void human_kb(unsigned long long kb, char *out, size_t n)
{
	if (kb >= 1024ULL * 1024ULL)
		snprintf(out, n, "%.1f GiB", (double)kb / (1024.0 * 1024.0));
	else
		snprintf(out, n, "%llu MiB", kb / 1024ULL);
}

static void add_uptime(void)
{
	char buf[64], out[VAL_MAX];
	double secs;

	if (read_line("/proc/uptime", buf, sizeof buf) != 0)
		return;
	secs = strtod(buf, NULL);

	unsigned long total = (unsigned long)secs;
	unsigned long days = total / 86400;
	unsigned long hours = (total % 86400) / 3600;
	unsigned long mins = (total % 3600) / 60;
	int len = 0;

	out[0] = '\0';
	if (days)
		len += snprintf(out + len, sizeof out - (size_t)len, "%lu day%s", days,
				days == 1 ? "" : "s");
	if (hours)
		len += snprintf(out + len, sizeof out - (size_t)len, "%s%lu hour%s",
				len ? ", " : "", hours, hours == 1 ? "" : "s");
	/* Only bother with minutes when they are the largest unit or close to it: "2 days,
	 * 3 hours, 7 mins" is more precision than an uptime line has ever needed. */
	if (!days && (mins || !hours))
		len += snprintf(out + len, sizeof out - (size_t)len, "%s%lu min%s",
				len ? ", " : "", mins, mins == 1 ? "" : "s");
	add("Uptime", "%s", out);
}

static void add_cpu(void)
{
	static const char *keys[] = { "model name", "Hardware", "Model", "cpu model" };
	char model[VAL_MAX] = "";
	long ncpu = sysconf(_SC_NPROCESSORS_ONLN);

	for (size_t i = 0; i < sizeof keys / sizeof keys[0]; i++)
		if (read_keyed("/proc/cpuinfo", keys[i], model, sizeof model) == 0)
			break;

	/* arm64's /proc/cpuinfo has no model string at all — only CPU implementer/part
	 * numbers, which would need a lookup table to be worth printing. The machine name
	 * is honest and costs nothing. */
	if (!model[0]) {
		struct utsname u;

		if (uname(&u) == 0)
			snprintf(model, sizeof model, "%s", u.machine);
	}
	if (!model[0])
		return;

	if (ncpu > 0)
		add("CPU", "%s (%ld)", model, ncpu);
	else
		add("CPU", "%s", model);
}

static void add_memory(void)
{
	unsigned long long total = meminfo_kb("MemTotal");
	unsigned long long avail = meminfo_kb("MemAvailable");
	char used_h[32], total_h[32];

	if (!total)
		return;
	/* MemAvailable, not MemFree: page cache is not memory anyone is missing. Older
	 * kernels without it fall back to counting everything as used, which is at least
	 * not a lie about the total. */
	unsigned long long used = avail <= total ? total - avail : total;

	human_kb(used, used_h, sizeof used_h);
	human_kb(total, total_h, sizeof total_h);
	add("Memory", "%s / %s (%llu%%)", used_h, total_h, used * 100 / total);
}

static void add_disk(void)
{
	struct statvfs s;
	char used_h[32], total_h[32];

	if (statvfs("/", &s) != 0 || s.f_blocks == 0)
		return;

	/* f_bavail rather than f_bfree: the root-reserved blocks are not space this
	 * system can spend, so counting them as free would overstate what is left. */
	unsigned long long unit = (unsigned long long)(s.f_frsize ? s.f_frsize : s.f_bsize);
	unsigned long long total = (unsigned long long)s.f_blocks * unit / 1024;
	unsigned long long used = (unsigned long long)(s.f_blocks - s.f_bavail) * unit / 1024;

	if (!total)
		return;
	human_kb(used, used_h, sizeof used_h);
	human_kb(total, total_h, sizeof total_h);
	add("Disk (/)", "%s / %s (%llu%%)", used_h, total_h, used * 100 / total);
}

static void add_load(void)
{
	char buf[128];
	double a, b, c;

	if (read_line("/proc/loadavg", buf, sizeof buf) != 0)
		return;
	if (sscanf(buf, "%lf %lf %lf", &a, &b, &c) != 3)
		return;
	add("Load", "%.2f %.2f %.2f", a, b, c);
}

static void add_host(void)
{
	char buf[VAL_MAX];

	/* x86 under qemu answers the first ("Standard PC (i440FX + PIIX, 1996)"); the
	 * arm64 virt board has no DMI but does have a device tree, whose model is
	 * "linux,dummy-virt". Neither is guaranteed, hence two tries and no third. */
	if (read_line("/sys/devices/virtual/dmi/id/product_name", buf, sizeof buf) == 0 ||
	    read_line("/proc/device-tree/model", buf, sizeof buf) == 0)
		add("Host", "%s", buf);
}

static void add_os(void)
{
	char buf[VAL_MAX];

	if (read_osrelease("PRETTY_NAME", buf, sizeof buf) == 0 ||
	    read_osrelease("NAME", buf, sizeof buf) == 0 ||
	    read_osrelease("ID", buf, sizeof buf) == 0)
		add("OS", "%s", buf);
}

static void add_header(void)
{
	struct passwd *pw = getpwuid(getuid());
	const char *user = pw && pw->pw_name ? pw->pw_name : getenv("USER");
	char host[VAL_MAX];
	char sep[VAL_MAX];

	if (gethostname(host, sizeof host) != 0)
		snprintf(host, sizeof host, "unknown");
	host[sizeof host - 1] = '\0';
	if (!user)
		user = "unknown";

	add("", "%s@%s", user, host);

	size_t n = strlen(user) + 1 + strlen(host);
	if (n >= sizeof sep)
		n = sizeof sep - 1;
	memset(sep, '-', n);
	sep[n] = '\0';
	add("", "%s", sep);
}

/* neofetch's colour bar, in a form that survives a C-locale console: background colours
 * behind spaces rather than block-drawing characters. */
static void print_swatch(int pad)
{
	if (!*c_logo)
		return;
	/* The dim row is 40-47 and the bright row 100-107 — the two standard background
	 * ranges, so this needs no 256-colour or truecolour support from the terminal. */
	static const int base[] = { 40, 100 };

	for (size_t row = 0; row < sizeof base / sizeof base[0]; row++) {
		printf("%*s  ", pad, "");
		for (int i = 0; i < 8; i++)
			printf("\033[%dm   ", base[row] + i);
		printf("\033[0m\n");
	}
}

static void usage(void)
{
	puts("usage: flfsfetch [--no-color] [--help]");
	puts("");
	puts("Print a short summary of this system. Colour is used when stdout is a");
	puts("terminal and NO_COLOR is unset.");
}

int main(int argc, char **argv)
{
	int color = isatty(STDOUT_FILENO) && !getenv("NO_COLOR");
	struct utsname u;
	char buf[VAL_MAX];

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "--no-color") || !strcmp(argv[i], "--no-colour")) {
			color = 0;
		} else if (!strcmp(argv[i], "-h") || !strcmp(argv[i], "--help")) {
			usage();
			return 0;
		} else {
			fprintf(stderr, "flfsfetch: unknown option: %s\n", argv[i]);
			return 2;
		}
	}

	if (color) {
		c_logo = "\033[1;36m";
		c_key = "\033[1;36m";
		c_off = "\033[0m";
	}

	add_header();
	add_os();
	add_host();
	if (uname(&u) == 0) {
		add("Kernel", "%s", u.release);
		add("Arch", "%s", u.machine);
	}
	if (read_line("/proc/1/comm", buf, sizeof buf) == 0)
		add("Init", "%s", buf);
	add_uptime();
	add_load();
	add_cpu();
	add_memory();
	add_disk();
	if (getenv("SHELL"))
		add("Shell", "%s", getenv("SHELL"));
	if (getenv("TERM"))
		add("Terminal", "%s", getenv("TERM"));

	int width = 0;
	for (int i = 0; i < LOGO_LINES; i++) {
		int len = (int)strlen(logo[i]);

		if (len > width)
			width = len;
	}

	int rows = LOGO_LINES > info_n ? LOGO_LINES : info_n;

	putchar('\n');
	for (int i = 0; i < rows; i++) {
		printf("%s%-*s%s  ", c_logo, width, i < LOGO_LINES ? logo[i] : "", c_off);
		if (i < info_n) {
			if (info[i].key[0])
				printf("%s%s%s: ", c_key, info[i].key, c_off);
			fputs(info[i].val, stdout);
		}
		putchar('\n');
	}
	putchar('\n');
	print_swatch(width);

	return 0;
}
