#!/bin/bash
# Disable lock screen, screen blanking, sleep, and hibernate on Kali Linux
# Run as: sudo bash kali-disable-sleep.sh

set -e

echo "=== Disabling sleep, hibernate, lock screen, and screen blanking ==="

# 1. Disable systemd sleep/hibernate/suspend targets
echo "Disabling systemd sleep targets..."
systemctl mask sleep.target suspend.target hibernate.target hybrid-sleep.target 2>/dev/null || true

# 2. Disable screen blanking at console level
echo "Disabling console screen blanking..."
setterm -blank 0 -powerdown 0 2>/dev/null || true

# Make persistent via kernel cmdline config
grep -q "consoleblank=0" /etc/default/grub 2>/dev/null || {
    sed -i 's/GRUB_CMDLINE_LINUX_DEFAULT="\(.*\)"/GRUB_CMDLINE_LINUX_DEFAULT="\1 consoleblank=0"/' /etc/default/grub
    update-grub 2>/dev/null || true
}

# 3. Disable DPMS (display power management) for X11
echo "Disabling DPMS and X11 screen saver..."
cat > /etc/X11/xorg.conf.d/10-no-blanking.conf 2>/dev/null << 'EOF' || true
Section "ServerFlags"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection

Section "ServerLayout"
    Identifier "ServerLayout0"
    Option "BlankTime" "0"
    Option "StandbyTime" "0"
    Option "SuspendTime" "0"
    Option "OffTime" "0"
EndSection
EOF
mkdir -p /etc/X11/xorg.conf.d 2>/dev/null || true

# 4. Disable XFCE power management and lock screen (Kali default desktop)
DESKTOP_USER=$(who | grep -E 'tty|:0' | head -1 | awk '{print $1}')
if [ -z "$DESKTOP_USER" ]; then
    DESKTOP_USER=$(getent passwd 1000 | cut -d: -f1)
fi

if [ -n "$DESKTOP_USER" ]; then
    echo "Configuring desktop settings for user: $DESKTOP_USER"
    UHOME=$(eval echo ~$DESKTOP_USER)

    # XFCE settings (Kali default)
    su - "$DESKTOP_USER" -c '
        # Disable XFCE power manager
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -s false 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -s 0 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -s 0 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -s 0 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -s 0 2>/dev/null || true
        xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/lock-screen-suspend-hibernate -s false 2>/dev/null || true

        # Disable XFCE screensaver / lock
        xfconf-query -c xfce4-screensaver -p /saver/enabled -s false 2>/dev/null || true
        xfconf-query -c xfce4-screensaver -p /lock/enabled -s false 2>/dev/null || true

        # Disable light-locker (Kali lock screen)
        xfconf-query -c xfce4-session -p /general/LockCommand -s "" 2>/dev/null || true

        # Disable xscreensaver if present
        xscreensaver-command -exit 2>/dev/null || true
    ' 2>/dev/null || true

    # Kill and disable light-locker
    pkill -f light-locker 2>/dev/null || true

    # Prevent light-locker from autostarting
    mkdir -p "$UHOME/.config/autostart" 2>/dev/null || true
    cat > "$UHOME/.config/autostart/light-locker.desktop" << 'EOF'
[Desktop Entry]
Hidden=true
EOF
    chown "$DESKTOP_USER:$DESKTOP_USER" "$UHOME/.config/autostart/light-locker.desktop"

    # Also disable the system-wide autostart
    if [ -f /etc/xdg/autostart/light-locker.desktop ]; then
        cp /etc/xdg/autostart/light-locker.desktop /etc/xdg/autostart/light-locker.desktop.bak
        echo "Hidden=true" >> /etc/xdg/autostart/light-locker.desktop
    fi

    # GNOME settings (in case GNOME is used instead)
    su - "$DESKTOP_USER" -c '
        gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
        gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
        gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
        gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type "nothing" 2>/dev/null || true
    ' 2>/dev/null || true
fi

# 5. Disable systemd idle action
echo "Disabling systemd idle action..."
mkdir -p /etc/systemd/logind.conf.d
cat > /etc/systemd/logind.conf.d/no-sleep.conf << 'EOF'
[Login]
IdleAction=ignore
IdleActionSec=0
HandleLidSwitch=ignore
HandleLidSwitchExternalPower=ignore
HandleSuspendKey=ignore
HandleHibernateKey=ignore
EOF

systemctl restart systemd-logind 2>/dev/null || true

echo ""
echo "=== Done ==="
echo "Sleep, hibernate, lock screen, and screen blanking are all disabled."
echo "This persists across reboots."
