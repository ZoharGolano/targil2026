# Targil2026 — תיעוד הקמת תשתית KVM ושרת Kubernetes ראשון

> **מצב הפרויקט:** המכונה `k3s-node01` הוקמה ונבדקה; **K3s, MongoDB, Argo CD והאפליקציה טרם הותקנו**. המסמך מתעד את העבודה שבוצעה בפועל ואת ההחלטות שהתקבלו. 
>
> **תאריך תיעוד:** 18 בנובמבר 2026. **סביבה:** מעבדת Ubuntu מקומית על מחשב נייד.

## 1. מטרת התרגיל

להקים סביבת Kubernetes לא־מנוהלת, לפרוס MongoDB ואפליקציה באמצעות Helm, להפעיל Argo CD ולבנות תהליך CI/CD עם בדיקות אבטחה. התהליך יתבצע בשלבים, וכל שלב יכלול **מטרה, הסבר, החלטת תכן, פקודות, בדיקות, תקלות ולקחים**.

המסמך הנוכחי מכסה רק את **הקמת בסיס הווירטואליזציה והמכונה הראשונה**.

## 2. סביבת העבודה והסייזינג

### מפרט המחשב המארח — נמדד בפועל

| מאפיין | ערך |
|---|---|
| מערכת הפעלה | Ubuntu Linux |
| מעבד | Intel Core i5-1135G7, ארבע ליבות פיזיות / 8 threads |
| תמיכה בווירטואליזציה | Intel VT-x |
| זיכרון | 31 GiB; בעת הבדיקה כ־25 GiB זמינים |
| דיסק | NVMe בנפח 476.9 GiB |
| מחיצת Root במחשב המארח | 467 GiB, מהם 427 GiB פנויים בעת הבדיקה |
| Hypervisor | KVM + QEMU 8.2.2 |
| כלי ניהול | libvirt/virsh 10.0.0, `virt-install`, `virt-manager` |

### תכנון מעבדת שלושת השרתים

| VM | vCPU | RAM | דיסק OS | דיסק `/var` | IP מתוכנן |
|---|---:|---:|---:|---:|---|
| `k3s-node01` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.11` |
| `k3s-node02` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.12` |
| `k3s-node03` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.13` |
| **סה"כ מתוכנן** | **6 vCPU** | **15 GiB** | **75 GiB** | **165 GiB** | |

**החלטה:** K3s עם שלושה שרתים, כשכל שרת מתוכנן לתפקידי Control Plane + embedded etcd + Worker. בחרנו בשלושה שרתים כדי ללמוד quorum, scheduling והתנהגות מול כשלי Node, למרות מגבלת המשאבים במחשב הנייד. נפחי QCOW2 הם **גבולות לוגיים** ולא נפח פיזי שמוקצה כולו מיד. יש לנטר את המקום הפנוי במארח.

**החלטת אחסון:** דיסק OS בנפח 25 GiB ודיסק נפרד בנפח 55 GiB עבור `/var`. ההפרדה מאפשרת לבודד נתוני Kubernetes ולוגים ממערכת ההפעלה ועונה להמלצת התרגיל לנפח `/var` של לפחות 50 GB. חלופה פשוטה יותר הייתה דיסק Root יחיד.

## 3. תשתית הווירטואליזציה: התקנה והרשאות

### בדיקות שבוצעו

```bash
lscpu | grep -E 'Model name|CPU\(s\)|Virtualization'
free -h
lsblk -o NAME,SIZE,TYPE,MOUNTPOINTS
df -h /
ls -l /dev/kvm
virsh --version
qemu-system-x86_64 --version
command -v virt-install
command -v virt-manager
```

אומת כי `/dev/kvm` קיים, QEMU ו־`virsh` מותקנים, ושני כלי היצירה והניהול זמינים. נבדקה גם גישה ל־libvirt:

```bash
virsh -c qemu:///system list --all
sudo virsh -c qemu:///system list --all
id
ls -l /var/run/libvirt/libvirt-sock
```

**תקלה:** הפקודה כמשתמש רגיל החזירה `Permission denied`, ואילו עם `sudo` הצליחה. ה־socket היה בבעלות `root:libvirt` עם הרשאות `srw-rw----`, והמשתמש לא היה חבר בקבוצת `libvirt`.

**פעולת תיקון שבוצעה:**

```bash
sudo usermod -aG libvirt,kvm zohargo
# יש להפעיל session חדש (למשל יציאה והתחברות מחדש)
id -nG
virsh -c qemu:///system list --all
```

המשתמש אישר שהחיבור ללא `sudo` תקין. **לקח:** יש לבדוק הרשאות Socket וקבוצות לפני אבחון תקלה ב־Hypervisor. חברות בקבוצת `libvirt` מאפשרת פעולות ניהול בעלות הרשאות נרחבות; יש להעניקה רק למשתמש מהימן.

## 4. רשת הווירטואליזציה

### בדיקה

```bash
virsh -c qemu:///system net-list --all
virsh -c qemu:///system net-dumpxml default
ip -br addr
```

**ממצאים בפועל:**

- רשת libvirt בשם `default` פעילה, קבועה (`Persistent`) ומוגדרת להפעלה אוטומטית.
- סוג רשת: **NAT**; bridge בשם `virbr0`.
- טווח: `192.168.122.0/24`; Gateway: `192.168.122.1`.
- DHCP: `192.168.122.2`–`192.168.122.254`.
- רשת המחשב המארח נצפתה על `wlan0` בכתובת `10.100.102.154/24` (ערך סביבתי, עשוי להשתנות).
- `virbr0` הופיע `DOWN` בהיעדר אורחים פעילים; הרשת עצמה הוגדרה `active` ב־libvirt.

**החלטה:** NAT במקום Bridge לרשת הפיזית: מאפשר תקשורת פנימית בין VMs ויציאה לאינטרנט, בלי תלות ב־Bridge מעל Wi-Fi. גישה לשירותים מחוץ למארח תדרוש פתרון חשיפה ייעודי אם נצטרך.

### DHCP Reservation עבור node01 — בוצע

```bash
virsh -c qemu:///system net-dhcp-leases default
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:11' name='k3s-node01' ip='192.168.122.11'/>" \
  --live --config
virsh -c qemu:///system net-dumpxml default
```

הרשומה הופיעה ב־XML:

```xml
<host mac='52:54:00:26:00:11' name='k3s-node01' ip='192.168.122.11'/>
```

אחרי ההפעלה התקבל Lease עבור `192.168.122.11/24` עם אותה כתובת MAC. **החלטה:** DHCP Reservation לפי MAC במקום כתובות ידניות בתוך כל VM. לפני יצירת VMs נוספות יש לוודא שה־MAC וה־IP החדשים פנויים.

## 5. Ubuntu Cloud Image ו־Cloud-init

### מיקום קובצי הפרויקט

```text
targil2026/
└── infrastructure/
    └── kvm/
        ├── cloud-init/
        │   └── user-data.yaml
        └── scripts/
```

הגדרות נשמרות בפרויקט; **דיסקי QCOW2 לא נשמרים ב־Git** אלא תחת `/var/lib/libvirt/images` במארח.

### מפתח SSH

נמצא מפתח ציבורי קיים: `~/.ssh/id_ed25519.pub`. הוא שולב בקובץ Cloud-init. **אין להכניס את המפתח הפרטי ל־Git, ל־README או לפקודות שיתוף.**

### Cloud-init עבור `k3s-node01`

הוכן קובץ `infrastructure/kvm/cloud-init/user-data.yaml` עם הגדרות דומות להלן (מפתח ציבורי מושמט מהתיעוד):

```yaml
#cloud-config
hostname: k3s-node01
manage_etc_hosts: true
users:
  - name: zohargo
    gecos: DevOps Lab User
    groups: [sudo]
    shell: /bin/bash
    sudo: "ALL=(ALL) NOPASSWD:ALL"
    lock_passwd: true
    ssh_authorized_keys:
      - <INSERT_YOUR_PUBLIC_SSH_KEY>
ssh_pwauth: false
package_update: true
packages:
  - curl
  - wget
  - vim
  - git
  - qemu-guest-agent
  - open-iscsi
  - nfs-common
runcmd:
  - systemctl enable --now qemu-guest-agent
```

**נימוק:** Cloud Image + Cloud-init מאפשרים לאתחל מכונות בצורה משוחזרת, ללא התקנת ISO ידנית. `NOPASSWD` הוא הקלה למעבדה בלבד, ולא תבנית בטוחה לסביבת Production.

### הורדת התמונה — בוצע

```bash
sudo mkdir -p /var/lib/libvirt/images/base
sudo wget \
  https://cloud-images.ubuntu.com/releases/noble/release/ubuntu-24.04-server-cloudimg-amd64.img \
  -O /var/lib/libvirt/images/base/ubuntu-24.04.img
sudo qemu-img info /var/lib/libvirt/images/base/ubuntu-24.04.img
```

נמדד: תמונה בפורמט QCOW2, גודל לוגי **3.5 GiB**, נפח פיזי **593 MiB**, ושדה `corrupt: false`. בדיקת `qemu-img info` אינה בדיקת checksum או אימות חתימה; ניתן להוסיף בדיקת checksum מול המקור הרשמי להגשה.

בדיקת חלוקת המחיצות בתמונת הבסיס:

```bash
sudo apt install -y libguestfs-tools
sudo virt-filesystems --long --parts --blkdevs \
  -a /var/lib/libvirt/images/base/ubuntu-24.04.img
```

זוהו מחיצות `sda1`, `sda14`, `sda15`, `sda16`. בהמשך זוהתה בפועל בתוך Ubuntu מחיצת Root מסוג ext4, מחיצת Boot ומחיצת EFI.

## 6. דיסקים עבור k3s-node01

נוצר תחילה דיסק OS בנפח 65 GiB, אך לפני הפעלת ה־VM הוחלט לשנות את התכנון לשני דיסקים. העותק הראשון נשמר באופן זמני בשם `k3s-node01.qcow2.old`; הוא אינו חלק מהפריסה הנוכחית, ויש לנקותו רק לאחר בדיקת הצורך בגיבוי.

### דיסק OS — 25 GiB

```bash
sudo cp /var/lib/libvirt/images/base/ubuntu-24.04.img \
  /var/lib/libvirt/images/k3s-node01.qcow2
sudo qemu-img resize /var/lib/libvirt/images/k3s-node01.qcow2 25G
sudo qemu-img info /var/lib/libvirt/images/k3s-node01.qcow2
```

**נמדד:** `virtual size: 25 GiB`, `disk size: 593 MiB`.

### דיסק `/var` — 55 GiB

```bash
sudo qemu-img create -f qcow2 \
  /var/lib/libvirt/images/k3s-node01-var.qcow2 55G
sudo qemu-img info /var/lib/libvirt/images/k3s-node01-var.qcow2
```

**נמדד:** `virtual size: 55 GiB`, `disk size: 196 KiB` כשהדיסק היה ריק.

**לקח:** `virtual size` שונה מהנפח הפיזי של קובץ QCOW2. יש להשאיר נפח פיזי פנוי במארח כדי למנוע כשל בעת גדילה.

## 7. יצירת המכונה הראשונה

ה־VM נוצרה עם `virt-install` (בתנאי שה־Cloud-init כבר מכיל מפתח SSH ציבורי תקין):

```bash
virt-install \
  --connect qemu:///system \
  --name k3s-node01 \
  --memory 5120 \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --import \
  --disk path=/var/lib/libvirt/images/k3s-node01.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k3s-node01-var.qcow2,format=qcow2,bus=virtio \
  --network network=default,model=virtio,mac=52:54:00:26:00:11 \
  --cloud-init user-data=$HOME/targil2026/infrastructure/kvm/cloud-init/user-data.yaml \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

**אימות:**

```bash
virsh -c qemu:///system list --all
virsh -c qemu:///system net-dhcp-leases default
ssh zohargo@192.168.122.11
# בתוך המכונה:
hostname
cloud-init status --long
lsblk -f
```

נמדד: VM במצב `running`, שם `k3s-node01`, `cloud-init status: done`, ללא שגיאות, מקור קונפיגורציה `DataSourceNoCloud`. שני הדיסקים נראו כ־`vda` ו־`vdb`. מחיצת Root התרחבה בעת האתחול. בדיקת זמן: Cloud-init הציג `last_update` בשנת 1970 — מומלץ לוודא Clock/NTP לפני התקנת K3s.

## 8. יצירת מערכת קבצים על דיסק `/var`

בתוך `k3s-node01`, הדיסק `/dev/vdb` זוהה בגודל 55 GiB וללא מערכת קבצים או Mount. לאחר בדיקה שאינו מכיל חתימות:

```bash
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
sudo wipefs -n /dev/vdb           # בדיקה בלבד
sudo mkfs.ext4 -L k3s-var /dev/vdb # פעולה הרסנית — רק על דיסק חדש וריק
lsblk -f
sudo blkid /dev/vdb
```

**נמדד:** label=`k3s-var`, type=`ext4`, UUID=`78158383-0fcd-4c5f-9e4c-30dacb80cbcf`.

הדיסק לא חובר מיד ל־`/var`, משום ש־Ubuntu כבר שמרה קובצי מערכת בספרייה. חיבור דיסק ריק מעליה היה מסתיר אותם.

### בדיקת `/var` לפני ההעברה

```bash
sudo du -shx /var
ls -ld /var
sudo du -h --max-depth=1 -x /var | sort -h
findmnt -R /var
```

נמדד: `/var` בנפח כ־397 MiB; מתוכם `/var/lib` כ־246 MiB, `/var/cache` כ־134 MiB ו־`/var/log` כ־17 MiB. לא נמצאו Mounts נוספים תחת `/var`.

## 9. העברת `/var` כשה־VM כבויה

### כיבוי

```bash
# מתוך ה־VM:
exit
# במחשב המארח:
virsh -c qemu:///system shutdown k3s-node01
virsh -c qemu:///system domstate k3s-node01  # shut off
```

**נימוק:** העתקה לא מקוונת מונעת כתיבות מקבילות של שירותים לקבצים בזמן ההעברה.

### ניסיון ראשון — guestmount/FUSE

```bash
sudo mkdir -p /mnt/targil-os /mnt/targil-var
sudo guestmount --rw \
  -a /var/lib/libvirt/images/k3s-node01.qcow2 \
  -m /dev/sda1 /mnt/targil-os
sudo guestmount --rw \
  -a /var/lib/libvirt/images/k3s-node01-var.qcow2 \
  -m /dev/sda /mnt/targil-var
sudo rsync -aHAX --numeric-ids --one-file-system --info=progress2 \
  /mnt/targil-os/var/ /mnt/targil-var/
```

**תקלה בפועל:**

```text
rsync: set_acl: sys_acl_set_file(.../log/journal/...): Invalid argument (22)
rsync error: some files/attrs were not transferred (code 23)
```

הבדיקה `getfacl` גילתה ACL נוסף לקבוצת `adm` על `/var/log/journal`. היעד הופיע כמערכת קבצים מסוג `fuse`. ההשערה הייתה שמגבלת ACL בשכבת הגישה דרך FUSE מנעה את שחזור המאפיינים ביעד. לא התעלמנו מ־exit code 23.

### ניתוק guestmount

```bash
sudo guestunmount /mnt/targil-os
sudo guestunmount /mnt/targil-var
findmnt /mnt/targil-os
findmnt /mnt/targil-var
```

לאחר הניתוק התקבל פלט ריק, כלומר ה־Mounts אינם פעילים.

### ניסיון שני — qemu-nbd, ext4 ישירות דרך המארח

> **זהירות:** אין לחבר QCOW2 דרך NBD כשה־VM פועלת, או כשהקובץ מחובר בכתיבה גם דרך guestmount. יש לבדוק שההתקנים `/dev/nbd0` ו־`/dev/nbd1` פנויים לפני חיבורם.

```bash
virsh -c qemu:///system domstate k3s-node01  # shut off
sudo modprobe nbd max_part=16
lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS /dev/nbd0 /dev/nbd1
for dev in nbd0 nbd1; do
  cat "/sys/class/block/$dev/pid" 2>/dev/null || echo "$dev not connected"
done
sudo qemu-nbd --connect=/dev/nbd0 --format=qcow2 \
  /var/lib/libvirt/images/k3s-node01.qcow2
sudo partprobe /dev/nbd0
sudo qemu-nbd --connect=/dev/nbd1 --format=qcow2 \
  /var/lib/libvirt/images/k3s-node01-var.qcow2
lsblk -o NAME,SIZE,FSTYPE,LABEL,UUID,MOUNTPOINTS /dev/nbd0 /dev/nbd1
```

**זוהה:** `nbd0p1` = Root ext4 בנפח 24 GiB; `nbd1` = ext4 בנפח 55 GiB עם UUID הצפוי.

```bash
sudo mount -o ro,noload /dev/nbd0p1 /mnt/targil-os
sudo mount /dev/nbd1 /mnt/targil-var
findmnt /mnt/targil-os
findmnt /mnt/targil-var
sudo rsync -aHAX --numeric-ids --one-file-system --info=progress2 \
  /mnt/targil-os/var/ /mnt/targil-var/
echo "rsync exit code: $?"
```

**נמדד בפועל:** `rsync exit code: 0`.

בדיקת השוואה שהורצה:

```bash
sudo rsync -aHAXnc --numeric-ids --one-file-system --itemize-changes \
  /mnt/targil-os/var/ /mnt/targil-var/
echo "Verification exit code: $?"
```

**נמדד:** `Verification exit code: 0`. המשתמש אישר שהבדיקות תקינות. **הערה:** Exit Code 0 מבטיח שהפקודה בוצעה ללא שגיאות; הוא לבדו אינו מבטיח שאין הבדלים — לכן חשוב לעיין גם בפלט `--itemize-changes` (צפוי ריק או הבדלים מוסברים).

### מדוע `rsync -aHAX`?

- `-a`: שמירת קבצים, תיקיות, בעלות, הרשאות בסיסיות ותאריכים.
- `-H`: Hard Links.
- `-A`: ACL.
- `-X`: Extended Attributes.
- `--numeric-ids`: שמירת UID/GID המספריים.
- `--one-file-system`: מניעת מעבר למערכות קבצים אחרות.
- `-n -c`: השוואת תוכן ללא כתיבה, לפי Checksums.

## 10. הגדרת Mount קבוע ב־fstab

לפני עריכת הקובץ, מחיצת Root נותקה מ־NBD ונבדקה:

```bash
sudo umount /mnt/targil-os
sudo e2fsck -fn /dev/nbd0p1
```

בדיקת `e2fsck` השלימה חמישה שלבים ללא דיווח על שגיאות. לאחר מכן:

```bash
sudo mount -o rw /dev/nbd0p1 /mnt/targil-os
findmnt -no SOURCE,FSTYPE,OPTIONS /mnt/targil-os
sudo cp -a /mnt/targil-os/etc/fstab /mnt/targil-os/etc/fstab.bak
```

הקובץ נבדק ונוסף בו Mount:

```fstab
LABEL=cloudimg-rootfs / ext4 discard,commit=30,errors=remount-ro 0 1
LABEL=BOOT /boot ext4 defaults 0 2
LABEL=UEFI /boot/efi vfat umask=0077 0 1
UUID=78158383-0fcd-4c5f-9e4c-30dacb80cbcf /var ext4 defaults 0 2
```

**תקלה קטנה:** הוספת הרשומה באמצעות `tee -a` בוצעה פעמיים והובילה לשורה כפולה. התיקון השאיר רשומה יחידה; הבדיקה החזירה `VAR entries: 1`.

**לקח מרכזי:** `tee -a` **אינו Idempotent** — הרצה נוספת מוסיפה שוב שורה. בסקריפט עתידי נשתמש בבדיקה/החלפה בטוחה או בתבנית המייצרת את הקובץ באופן צפוי.

## 11. סיום המיגרציה והפעלת המכונה

```bash
# מחשב מארח; VM כבויה
sync
sudo umount /mnt/targil-var
sudo umount /mnt/targil-os
findmnt /mnt/targil-var
findmnt /mnt/targil-os
sudo qemu-nbd --disconnect /dev/nbd0
sudo qemu-nbd --disconnect /dev/nbd1
virsh -c qemu:///system start k3s-node01
ssh zohargo@192.168.122.11
```

בדיקות מתוך המכונה:

```bash
findmnt /var
df -h /var
lsblk -f
systemctl --failed
```

**תוצאה:** המשתמש אישר כי ארבע הבדיקות תקינות. לפיכך סומנה הפרדת `/var` כהושלמה; הפלט המלא של בדיקות האתחול אינו כלול בשיחה ולכן אינו משוחזר כאן.

**אסטרטגיית Rollback:** נשמרו `/var` המקורי בדיסק OS וגיבוי `fstab.bak`. אם ה־VM אינה עולה, יש לכבותה ולשחזר את ההגדרה דרך כלי תחזוקה מתאימים; אין להפעילה כשדיסקיה מחוברים בכתיבה למארח.

## 12. החלטות התכן — סיכום

| החלטה | נימוק | הסתייגות |
|---|---|---|
| K3s | חלוקה קלה יחסית ומתאימה למעבדה | טרם הותקן; נוודא תאימות וגרסה |
| שלוש VMs | לימוד HA, quorum ו־Scheduling | צריך לתכנן גם endpoint יציב ל־API |
| NAT | גישה פנימית ואינטרנט בלי Bridge פיזי | גישה חיצונית דורשת תכנון |
| DHCP Reservations | כתובות צפויות ממיקום מרכזי | מותנה בשירות DHCP של libvirt |
| Ubuntu Cloud Image + Cloud-init | Provisioning עקבי וחוזר | אין לשכפל machine-id או SSH host keys מ־VM שהופעלה |
| QCOW2 | אחסון דינמי | יש לנטר מקום במארח |
| `/var` על ext4 נפרד | בידוד נתוני K3s ולוגים | דורש העברה זהירה של קובצי מערכת |
| Migration אופליין | קבצים לא משתנים באמצע ההעתקה | זמן השבתה של VM |
| rsync + NBD | שמירת ACL/XATTR לאחר כשל FUSE | NBD מחייב בדיקות בטיחות |
| UUID ב־fstab | Mount יציב גם אם שם ההתקן משתנה | יש לבדוק תקינות אחרי reboot |

## 13. מצב נוכחי ומשימות להמשך

**הושלם:** `k3s-node01` עם Ubuntu 24.04, כתובת `192.168.122.11`, SSH, Cloud-init, דיסק OS ‏25 GiB ודיסק `/var` ‏55 GiB; המשתמש אישר עלייה תקינה ושירותים תקינים לאחר העברת `/var`.

**טרם בוצע:** יצירה והקשחה בסיסית/בדיקת זמן של `k3s-node02` ו־`k3s-node03`; קיבוע גרסאות K3s; הקמת cluster עם embedded etcd; התקנת Helm; Argo CD; MongoDB 8.0.13; אפליקציה; CI/CD ו־GitOps.

### צעדי ההמשך המומלצים

1. להפוך את יצירת ה־VMs והגדרת `/var` לסקריפט משוחזר/Cloud-init, ולא לחזור על מיגרציה ידנית של `/var` לכל VM.
2. ליצור לכל VM **זהות ייחודית** (hostname, MAC, machine-id, SSH host keys) ודיסקים עצמאיים מתמונת המקור.
3. להגדיר DHCP Reservations ל־`.12` ול־`.13`, אחרי בדיקת התנגשויות.
4. לוודא `timedatectl`, DNS ויציאה לאינטרנט בכל שלוש המכונות.
5. לבדוק זמינות משאבי מארח ו־VMs לפני התקנת K3s.
6. לאחר מכן להתחיל התקנת K3s בשלבים עם אימות Node ו־etcd quorum.

## 14. פקודות בדיקה מהירה

```bash
# במארח
virsh -c qemu:///system list --all
virsh -c qemu:///system net-list --all
virsh -c qemu:///system net-dhcp-leases default
df -h /

# במכונה
hostname
cloud-init status --long
lsblk -f
findmnt /var
df -h /var
systemctl --failed
```

---

**כללי בטיחות:** פקודות כגון `mkfs`, `wipefs` ללא `-n`, חיבור QCOW2 לכתיבה, `qemu-nbd --connect` ועריכת `fstab` עלולות לפגוע בנתונים אם מציינים התקן שגוי. לעולם אין להפעיל VM במקביל לעריכת הדיסקים שלה מהמארח. אין להעלות לקוד מפתחות SSH פרטיים, סיסמאות או דיסקי QCOW2.
