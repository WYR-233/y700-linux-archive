// Y700 振动测试（标准 FF 流程，与游戏/SDL 一致）
// 用法：./fftest [/dev/input/eventN] [强度0-65535] [时长ms]
#define _GNU_SOURCE
#include <stdio.h>
#include <stdlib.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <linux/input.h>

int main(int argc, char **argv)
{
    const char *dev = argc > 1 ? argv[1] : "/dev/input/event2";
    int mag = argc > 2 ? atoi(argv[2]) : 50000;
    int dur = argc > 3 ? atoi(argv[3]) : 1200;

    int fd = open(dev, O_RDWR);
    if (fd < 0) { perror("open"); return 1; }

    unsigned long ffbit[8] = {0};
    if (ioctl(fd, EVIOCGBIT(EV_FF, sizeof(ffbit)), ffbit) < 0)
        perror("EVIOCGBIT(EV_FF)");
    printf("[i] %s: FF 能力位 0x%lx（bit0x50=FF_RUMBLE: %s）\n", dev, ffbit[0],
           (ffbit[0] >> FF_RUMBLE) & 1 ? "支持" : "不支持");

    struct ff_effect e;
    memset(&e, 0, sizeof(e));
    e.type = FF_RUMBLE;
    e.id = -1;
    e.u.rumble.strong_magnitude = mag;
    e.u.rumble.weak_magnitude = mag;
    e.replay.length = dur;
    e.replay.delay = 0;

    if (ioctl(fd, EVIOCSFF, &e) < 0) {
        printf("[!] EVIOCSFF 失败: %s（errno=%d）\n", strerror(errno), errno);
        close(fd);
        return 2;
    }
    printf("[+] 效果已上传: id=%d\n", e.id);

    struct input_event ev;
    memset(&ev, 0, sizeof(ev));
    ev.type = EV_FF; ev.code = e.id; ev.value = 1;
    if (write(fd, &ev, sizeof(ev)) < 0) { perror("write play"); return 3; }
    printf("[+] 已 play（力度 %d，时长 %dms）——设备应该在抖\n", mag, dur);

    usleep((dur + 300) * 1000);

    memset(&ev, 0, sizeof(ev));
    ev.type = EV_FF; ev.code = e.id; ev.value = 0;
    write(fd, &ev, sizeof(ev));
    ioctl(fd, EVIOCRMFF, e.id);
    printf("[✓] 已 stop 并回收效果\n");
    close(fd);
    return 0;
}
