// vibpatt.c — Y700 振动节奏播放器（一次进程内播放多段，节奏精确到 ms）
// 用法：vibpatt <dev> <delay_ms>:<level>:<dur_ms> [...]
//   例：vibpatt /dev/input/event2 0:50000:40 90:50000:40      # 立即 40ms，隔 90ms 再来一次
//       vibpatt /dev/input/event2 0:60000:500                    # 长震 500ms
// level: 0-65535（驱动按 level*0x80/0xffff 量化 → 实际只有 0..128 档，<512 无效）
// 依据 aw86927.c：input_ff_create_memless + play 内部比较 level，相同力度不重播；
// 因此每段结束都显式 stop（value=0），使下一段能从 0 重新起振。
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>
#include <time.h>
#include <linux/input.h>

static void msleep(long ms)
{
    struct timespec ts = { ms / 1000, (ms % 1000) * 1000000L };
    while (nanosleep(&ts, &ts) == -1) ;
}

int main(int argc, char **argv)
{
    if (argc < 3) {
        fprintf(stderr, "用法: %s <dev> <delay_ms>:<level>:<dur_ms> [...]\n"
                        "  例: %s /dev/input/event2 0:50000:40 90:50000:40\n",
                argv[0], argv[0]);
        return 1;
    }

    const char *dev = argv[1];
    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    struct ff_effect e;
    memset(&e, 0, sizeof(e));
    e.type = FF_RUMBLE;
    e.id = -1;
    e.replay.length = 1;
    e.replay.delay = 0;
    e.u.rumble.strong_magnitude = 32768;
    e.u.rumble.weak_magnitude = 32768;
    if (ioctl(fd, EVIOCSFF, &e) < 0) { perror("EVIOCSFF"); close(fd); return 2; }

    struct input_event ev;
    int n = 0;
    for (int i = 2; i < argc; i++) {
        long delay = 0, level = 0, dur = 0;

        if (sscanf(argv[i], "%ld:%ld:%ld", &delay, &level, &dur) != 3) {
            fprintf(stderr, "参数格式错: %s\n", argv[i]);
            continue;
        }
        if (level > 65535) level = 65535;
        if (level < 0) level = 0;

        msleep(delay);
        e.u.rumble.strong_magnitude = level;
        e.u.rumble.weak_magnitude = level;
        e.replay.length = dur;
        if (ioctl(fd, EVIOCSFF, &e) < 0) { perror("EVIOCSFF 更新"); break; }

        memset(&ev, 0, sizeof(ev));
        ev.type = EV_FF; ev.code = e.id; ev.value = 1;
        if (write(fd, &ev, sizeof(ev)) < 0) { perror("play"); break; }

        msleep(dur);

        memset(&ev, 0, sizeof(ev));
        ev.type = EV_FF; ev.code = e.id; ev.value = 0;
        write(fd, &ev, sizeof(ev));

        n++;
        fprintf(stderr, "  段%d: 延迟%ldms 力度%ld(档%ld) 时长%ldms\n",
                n, delay, level, level * 0x80 / 0xffff, dur);
    }

    memset(&ev, 0, sizeof(ev));
    ev.type = EV_FF; ev.code = e.id; ev.value = 0;
    write(fd, &ev, sizeof(ev));
    ioctl(fd, EVIOCRMFF, e.id);
    close(fd);
    fprintf(stderr, "[✓] 已播放 %d 段\n", n);
    return 0;
}
