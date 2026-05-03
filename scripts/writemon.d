#!/usr/sbin/dtrace -qs
/*
 * writemon.d — per-PID stdout/stderr capture for the AI Sandbox guest.
 *
 * Tails write(2) / write_nocancel(2) syscalls for one specific PID,
 * filtered to fd 1 (stdout) and fd 2 (stderr), one record per syscall.
 * Designed to be invoked on demand by ai-mon over `secvf-cli vm ssh`,
 * not as a long-lived LaunchDaemon — its lifetime tracks the consumer.
 *
 * Wire format (one record per line):
 *
 *     write(FD, "ESCAPED_BYTES", LEN) = RET
 *
 * dtrace's "%S" specifier emits non-printable bytes as octal escapes
 * (\NNN) — identical to strace's default output, so consumers can use
 * the same unescaper. UTF-8 round-trips cleanly through latin1.
 *
 * Usage:
 *     sudo dtrace -p $TARGET_PID -s writemon.d
 *
 * `-p` makes dtrace exit when the target exits, so a closing ssh stream
 * is the natural end-of-life signal for the consumer.
 */

#pragma D option strsize=64k
#pragma D option switchrate=10hz
#pragma D option quiet

/*
 * Capture buf/fd/len at entry. Doing it at entry (not return) ensures we
 * see the *requested* byte count and the userspace contents the caller
 * asked to write — which is what stdout/stderr consumers care about,
 * even if the kernel partially writes.
 */
syscall::write:entry,
syscall::write_nocancel:entry
/pid == $target && (arg0 == 1 || arg0 == 2)/
{
    self->fd  = arg0;
    self->len = arg2;
    self->buf = copyinstr(arg1, arg2);
}

syscall::write:return,
syscall::write_nocancel:return
/self->buf != NULL/
{
    printf("write(%d, \"%S\", %d) = %d\n",
           self->fd, self->buf, self->len, (int)arg1);
    self->fd  = 0;
    self->len = 0;
    self->buf = 0;
}
