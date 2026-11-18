# Targil2026 — תיעוד תשתית KVM לשלושה שרתי Kubernetes

> **מצב הפרויקט:** שלוש מכונות Ubuntu (`k3s-node01`, `k3s-node02`, `k3s-node03`) הוקמו ונבדקו. **K3s הותקן בהצלחה בשלושה שרתים וניסוי HA ראשוני הושלם; MongoDB, Argo CD והאפליקציה טרם הותקנו**. המסמך מתעד את הפעולות שאושרו בפועל ומפריד בינן לבין שלבים מתוכננים. 
>
> **תאריך תיעוד:** 18 בנובמבר 2026. **סביבה:** מעבדת Ubuntu מקומית על מחשב נייד.

## 1. מטרת התרגיל

להקים סביבת Kubernetes לא־מנוהלת, לפרוס MongoDB ואפליקציה באמצעות Helm, להפעיל Argo CD ולבנות תהליך CI/CD עם בדיקות אבטחה. התהליך יתבצע בשלבים, וכל שלב יכלול **מטרה, הסבר, החלטת תכן, פקודות, בדיקות, תקלות ולקחים**.

המסמך מכסה את **הקמת תשתית הווירטואליזציה ושלושת שרתי Ubuntu**, את האוטומציה שהוספנו, ואת הבדיקות לפני K3s. להמשך שבוצע בפועל — התקנת K3s, חברי etcd וניסוי HA — ראו [`02-k3s-ha-he.md`](02-k3s-ha-he.md).

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

### תצורת מעבדת שלושת השרתים — הוקמה בפועל

| VM | vCPU | RAM | דיסק OS | דיסק `/var` | IP |
|---|---:|---:|---:|---:|---|
| `k3s-node01` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.11` |
| `k3s-node02` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.12` |
| `k3s-node03` | 2 | 5 GiB | 25 GiB | 55 GiB | `192.168.122.13` |
| **סה"כ לוגי** | **6 vCPU** | **15 GiB** | **75 GiB** | **165 GiB** | |

**החלטה:** K3s עם שלושה שרתים, כשכל שרת מתפקד בפועל בתפקידי Control Plane + embedded etcd + Worker. בחרנו בשלושה שרתים כדי ללמוד quorum, scheduling והתנהגות מול כשלי Node, למרות מגבלת המשאבים במחשב הנייד. נפחי QCOW2 הם **גבולות לוגיים** ולא נפח פיזי שמוקצה כולו מיד. יש לנטר את המקום הפנוי במארח.

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

## 11א. אוטומציה להקמת node02 ו־node03

לאחר יצירת `k3s-node01` ידנית יחסית, עברנו לתהליך חוזר באמצעות הסקריפטים:

```text
infrastructure/kvm/
├── cloud-init/
│   ├── user-data.yaml
│   ├── node02-user-data.yaml
│   └── node03-user-data.yaml
└── scripts/
    ├── create-vm-disks.sh
    ├── prepare-var-disk.sh
    └── prepare-var-disk.sh.bak   # גיבוי מקומי; אין צורך להעלות ל־Git
```

### יצירת זהות ייחודית וכתובות שמורות

לקובצי ה־Cloud-init הוגדרו `hostname: k3s-node02` ו־`hostname: k3s-node03`, המשתמש `zohargo`, ו־`ssh_authorized_keys`. לא פורסם המפתח הפרטי.

הוספו/אומתו רשומות DHCP ברשת `default` של libvirt:

```bash
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:12' name='k3s-node02' ip='192.168.122.12'/>" \
  --live --config
virsh -c qemu:///system net-update default add ip-dhcp-host \
  "<host mac='52:54:00:26:00:13' name='k3s-node03' ip='192.168.122.13'/>" \
  --live --config
```

> הפקודות לעיל הן תיעוד ההגדרה; **אין להריץ `net-update add` שוב** אם הרשומות כבר קיימות. בדיקה בטוחה: `virsh -c qemu:///system net-dumpxml default`.

### יצירת דיסקים: `create-vm-disks.sh`

```bash
cd ~/targil2026
./infrastructure/kvm/scripts/create-vm-disks.sh k3s-node02
./infrastructure/kvm/scripts/create-vm-disks.sh k3s-node03
```

הסקריפט מקבל רק שמות `k3s-node02` או `k3s-node03`, דורש שתמונת הבסיס קיימת וששמות הדיסקים וה־VM עדיין אינם בשימוש, מעתיק תמונת Ubuntu, מגדיל את דיסק ה־OS ל־25GiB ויוצר QCOW2 ריק בגודל 55GiB עבור `/var`.

**נצפה:** לשני השרתים דיסק OS בגודל לוגי 25GiB ובנפח פיזי ראשוני כ־593MiB, ודיסק VAR לוגי 55GiB ובנפח פיזי ראשוני כ־196KiB; בשניהם `corrupt: false` לפי `qemu-img info`.

### הכנת דיסק `/var`: `prepare-var-disk.sh`

```bash
# דוגמה להפעלה ראשונית בלבד — הפקודות כבר הורצו בהצלחה ואין להריצן שוב!
sudo ./infrastructure/kvm/scripts/prepare-var-disk.sh k3s-node02
sudo ./infrastructure/kvm/scripts/prepare-var-disk.sh k3s-node03
```

הסקריפט מאמת ששם המכונה מותר, שה־VM אינה קיימת ב־libvirt, ושהתקני NBD פנויים. הוא מחבר את דיסק OS ל־`/dev/nbd0` ואת דיסק VAR ל־`/dev/nbd1`, מזהה מחיצת Root ב־`/dev/nbd0p1`, מוודא שדיסק הנתונים ללא חתימות ומחיצות, יוצר ext4, ומעתיק את התוכן המקורי של `/var` באמצעות:

```bash
rsync -aHAX --numeric-ids --one-file-system SOURCE/var/ TARGET/
rsync -aHAXnc --numeric-ids --one-file-system --itemize-changes SOURCE/var/ TARGET/
```

לאחר אימות פלט ריק בבדיקת ההשוואה, הוא מגבה את `fstab` ומוסיף רשומת `/var` באמצעות UUID. ב־node02 וב־node03 זוהתה רשומה אחת עם ה־UUID הנכון בעזרת `virt-cat`, ללא הפעלת המכונה.

**זהירות:** `mkfs.ext4` הוא הרסני. הסקריפט מיועד לדיסקים חדשים בלבד; הוא **אינו** תהליך Idempotent מלא, ו**אסור להריצו פעם נוספת** על דיסק `/var` שכבר הוכן. הבדיקות האוטומטיות מצמצמות סיכון, אך אינן מחליפות גיבוי ואימות זהות הדיסק.

### Troubleshooting — `umount: target is busy`

ב־node02 ההעתקה ואימות `rsync` הצליחו, ו־`fstab` עודכן, אך ה־Cleanup נכשל בניסיון ניתוק דיסק VAR:

```text
umount: /mnt/targil-var.3Mq6HA: target is busy
ERROR: A filesystem is still mounted.
NBD devices were not disconnected.
```

`fuser -vm` הציג רק `root kernel mount`, ללא תהליך משתמש שזוהה. בוצע `sudo umount` רגיל בהצלחה, ואז נותקו `/dev/nbd1` ו־`/dev/nbd0`. אומת ששניהם חזרו לגודל `0B` ב־`lsblk`. **שורש התקלה המדויק לא זוהה**; אין לפרש `kernel mount` כהוכחה לקיומו של תהליך שחוסם את הניתוק.

לקראת node03 גובתה גרסת הסקריפט ונוספה פונקציית `safe_umount` עם עד חמישה ניסיונות ניתוק והשהיית שתי שניות ביניהם, ללא ניתוק כפוי. `bash -n` עבר והפונקציה הופיעה בהגדרה ובשתי קריאות Cleanup.

ב־node03 נרשמו שני כישלונות זמניים ולאחריהם הצלחה בניסיון השלישי:

```text
Unmount attempt 1 failed
Unmount attempt 2 failed
Unmount successful: /mnt/targil-var.UTDiPS
Unmount successful: /mnt/targil-os.b1w9Vw
/dev/nbd1 disconnected
/dev/nbd0 disconnected
Preparation completed successfully.
Exit code: 0
```

בדיקת `lsblk` הראתה `nbd0 0B` ו־`nbd1 0B`. **לקח:** `trap` מועיל לניקוי, אך כשל `umount` זמני עשוי לדרוש Retry מוגבל ובדיקת הניתוק בפועל. אין להשתמש ב־`umount -f`, ‏`umount -l` או בניתוק NBD כשהמערכת עדיין מחוברת.

### יצירת המכונות עם virt-install

```bash
# דוגמה — node03, בוצע כבר. אין להריץ על VM קיימת.
virt-install \
  --connect qemu:///system \
  --name k3s-node03 \
  --memory 5120 \
  --vcpus 2 \
  --os-variant ubuntu24.04 \
  --import \
  --disk path=/var/lib/libvirt/images/k3s-node03.qcow2,format=qcow2,bus=virtio \
  --disk path=/var/lib/libvirt/images/k3s-node03-var.qcow2,format=qcow2,bus=virtio \
  --network network=default,model=virtio,mac=52:54:00:26:00:13 \
  --cloud-init user-data=$HOME/targil2026/infrastructure/kvm/cloud-init/node03-user-data.yaml \
  --graphics none \
  --console pty,target_type=serial \
  --noautoconsole
```

ה־VMs קיבלו כתובות `.12` ו־`.13` והתחברנו אליהן ב־SSH. Cloud-init השלים `status: done`, ‏`errors: []`. בשתי המכונות `/var` מותקן על `/dev/vdb` מסוג ext4, מערכת הקבצים מדווחת על נפח 54GiB ושימוש התחלתי של כ־1%, מחיצת Root גדלה אוטומטית, ו־`systemctl --failed` הציג 0 יחידות כושלות.

## 11ב. בדיקות רשת ומוכנות ל־K3s

### בדיקות על node03 — בוצעו

```bash
ping -c 3 192.168.122.11
ping -c 3 192.168.122.12
systemctl is-active ssh
ip -br addr
ip route
```

**תוצאות:** שתי בדיקות ה־Ping החזירו `3 transmitted, 3 received, 0% packet loss`; זמני תגובה ממוצעים כ־0.529ms ל־node01 וכ־0.830ms ל־node02; `ssh=active`; כתובת `enp1s0` היא `192.168.122.13/24`; שער ברירת המחדל `192.168.122.1`. בדיקת ICMP אינה מחליפה בדיקת פורטים TCP/UDP.

### בדיקות על node01 — בוצעו

```bash
hostname
free -h
df -h /var
swapon --show
sudo ufw status
curl -I --connect-timeout 5 https://get.k3s.io
```

**תוצאות:** `k3s-node01`; סך זיכרון 4.8GiB, כ־4.4GiB זמינים בזמן הבדיקה; `/var` בגודל 54GiB, כ־51GiB פנויים; Swap ‏0B; `ufw: inactive`; אתר `https://get.k3s.io` השיב HTTP/2 200. אין עדיין אישור להורדת קובצי ההתקנה והתמונות הדרושות.

**תכנון K3s הבא:** שלושה `server` nodes עם embedded etcd (כל אחד גם Worker). סדר הצירוף: node01 עם `cluster-init`, אחריו node02 ו־node03. צירוף של שלושה שרתי etcd יספק quorum של שניים מתוך שלושה, אך לא יתירות בפני כשל של המחשב המארח היחיד. מומלץ לקבע גרסת K3s ולאשר שעון/NTP לפני ההתקנה.

## 12. החלטות התכן — סיכום

| החלטה | נימוק | הסתייגות |
|---|---|---|
| K3s | הפצת Kubernetes קלה יחסית ומתאימה למעבדה | הותקן בגרסה `v1.37.2+k3s1`; פירוט במסמך 02 |
| שלוש VMs | לימוד HA, quorum ו־Scheduling | צריך לתכנן גם endpoint יציב ל־API |
| NAT | גישה פנימית ואינטרנט בלי Bridge פיזי | גישה חיצונית דורשת תכנון |
| DHCP Reservations | כתובות צפויות ממיקום מרכזי | מותנה בשירות DHCP של libvirt |
| Ubuntu Cloud Image + Cloud-init | Provisioning עקבי וחוזר | אין לשכפל machine-id או SSH host keys מ־VM שהופעלה |
| QCOW2 | אחסון דינמי | יש לנטר מקום במארח |
| `/var` על ext4 נפרד | בידוד נתוני K3s ולוגים | דורש העברה זהירה של קובצי מערכת |
| Migration אופליין | קבצים לא משתנים באמצע ההעתקה | זמן השבתה של VM |
| rsync + NBD | שמירת ACL/XATTR לאחר כשל FUSE | NBD מחייב בדיקות בטיחות |
| UUID ב־fstab | Mount יציב גם אם שם ההתקן משתנה | יש לבדוק תקינות אחרי reboot |

## 13. מצב התשתית בעת סיום שלב ה־VMs — 18.11.2026

**הושלם בשלב התשתית:** הקמת שלוש מכונות Ubuntu 24.04 עם 2 vCPU, ‏5120MiB RAM, דיסק OS ‏25GiB, ודיסק ext4 ייעודי ‏55GiB המותקן על `/var`. הוגדרו שמות ייחודיים וכתובות IP קבועות באמצעות DHCP Reservations. נבדקו Cloud-init, אחסון ותקשורת. **מאוחר יותר הותקן K3s, כמתועד במסמך 02.**

| מכונה | IP | MAC | דיסק `/var` | תוצאה מאומתת |
|---|---|---|---|---|
| `k3s-node01` | `192.168.122.11` | `52:54:00:26:00:11` | `78158383-0fcd-4c5f-9e4c-30dacb80cbcf` | פעילה, אחסון נבדק; מוכנות ראשונית ל־K3s נבדקה |
| `k3s-node02` | `192.168.122.12` | `52:54:00:26:00:12` | `59b0ccac-a854-4753-a763-dba4b4a66adf` | SSH תקין, Cloud-init `done`, `/var` על `vdb`, 0 יחידות systemd שנכשלו |
| `k3s-node03` | `192.168.122.13` | `52:54:00:26:00:13` | `87e88eec-efc2-4999-9a97-4f444b7656cc` | Cloud-init `done`, `/var` על `vdb`, 0 יחידות systemd שנכשלו, רשת נבדקה |

### בדיקות מוכנות שכבר בוצעו בשרת הראשון

```bash
hostname
free -h
df -h /var
swapon --show
sudo ufw status
curl -I --connect-timeout 5 https://get.k3s.io
```

**נצפה בפועל:** `hostname=k3s-node01`; זיכרון כולל 4.8GiB וזמין 4.4GiB; דיסק `/var` בגודל מערכת קבצים 54GiB, מתוכם כ־51GiB פנויים; ללא Swap; `ufw` לא פעיל; `get.k3s.io` החזיר HTTP/2 200. בדיקת `curl -I` אינה מבטיחה זמינות של כל קובצי הבינארי/Images הנחוצים להתקנה.

**בדיקות שנותרו לפני/במהלך התקנת K3s:** לוודא `timedatectl` ו־NTP, DNS ותקשורת TCP בפורטים הרלוונטיים; לבדוק גרסה זמינה של K3s ולבחור גרסה קבועה; לתכנן Kubernetes API endpoint יציב לפי צורך.

**בוצע לאחר מכן (ראו מסמך 02):** אתחול `k3s-node01` כשרת K3s עם embedded etcd, צירוף node02 ו־node03, אימות quorum של 2 מתוך 3, וגיבוי וניסוי HA מבוקר. שלוש ה־VMs פועלות על מחשב מארח יחיד, ולכן אין עמידות לכשל במחשב המארח.

**שלבים מאוחרים יותר (טרם בוצעו):** התקנת MongoDB 8.0.13 באמצעות Helm, ‏Argo CD, אפליקציית התרגיל, GitHub Actions, ‏SAST, ‏Trivy ו־GitOps.

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
