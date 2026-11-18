# Targil2026 — התקנת K3s, אימות etcd וניסוי High Availability

> **עדכון:** 18 בנובמבר 2026  
> **סטטוס מאומת:** שלושה שרתי K3s בגרסה `v1.37.2+k3s1` במצב `Ready`; שלושה חברי etcd מצביעים ובריאים; Snapshot ידני נוצר; ניסוי עצירת K3s ב־node02 עבר והשרת התאושש.  
> **טרם בוצע:** ניסוי כשל Leader, שחזור Snapshot, העתקת גיבוי למקום חיצוני, API load balancer/כתובת HA יציבה, פריסת MongoDB, Helm לאפליקציה, Argo CD ו־CI/CD.  
> **מסמך קודם:** [`01-infrastructure-setup-he.md`](01-infrastructure-setup-he.md).

## 1. מטרת השלב והארכיטקטורה

להקים Kubernetes בהפצת K3s בשלוש מכונות Ubuntu 24.04.5 LTS, כאשר כל שרת מבצע תפקידי Control Plane, ‏etcd ויכול להריץ Workloads. משתמשים ב־**embedded etcd** וב־**Raft quorum** של שניים מתוך שלושה. התצורה עמידה מבחינת קוורום לכשל בשרת אחד, אך לא לכשל במחשב המארח הפיזי היחיד.

```text
                      Ubuntu Laptop — KVM/libvirt
                       NAT 192.168.122.0/24
                                |
                       K3s v1.37.2+k3s1
                                |
             +------------------+------------------+
             |                  |                  |
      k3s-node01           k3s-node02           k3s-node03
      192.168.122.11       192.168.122.12       192.168.122.13
      Control Plane        Control Plane        Control Plane
      etcd voting member   etcd voting member   etcd voting member
      schedulable          schedulable          schedulable
             +------------------+------------------+
                        Raft quorum = 2/3
```

| פרמטר | תוצאה שנמדדה |
|---|---|
| VM לכל שרת | 2 vCPU, ‏5120 MiB RAM, ‏25 GiB OS + ‏55 GiB דיסק ext4 עבור `/var` |
| גרסת מערכת הפעלה | Ubuntu 24.04.5 LTS |
| K3s/Kubernetes | `v1.37.2+k3s1`, build `f6973cb8` |
| containerd | `2.3.7-k3s1` |
| etcd server | `3.7.1` |
| etcdctl client (node03) | `3.4.30`, API v3 |
| תפקידי Nodes | `control-plane,etcd`; לא הוגדר taint המונע Workloads |
| רשת | IPs שמורים ב־libvirt DHCP; Kubernetes API ב־TCP 6443 |

**החלטת תכן:** להשתמש ב־K3s server בכל VM, לא ב־agent, משום שהמטרה היא להתנסות ב־Control Plane HA וב־embedded etcd. **מגבלה:** הפקודה `server: https://192.168.122.11:6443` בשרתים המצטרפים מצביעה ל־node01; לא הוקם עדיין Load Balancer יציב עבור לקוחות API או צירופי שרתים עתידיים.

## 2. בדיקות מוכנות לפני ההתקנה — בוצעו

ב־node01:

```bash
hostname
free -h
df -h /var
swapon --show
sudo ufw status
curl -I --connect-timeout 5 https://get.k3s.io
```

**תוצאות:** `k3s-node01`, ‏4.8GiB זיכרון (כ־4.4GiB זמינים בבדיקה), ‏54GiB filesystem עבור `/var` (כ־51GiB פנויים), ללא Swap, ‏UFW לא פעיל, ו־HTTP 200 ל־`get.k3s.io`. תגובת HTTP 200 לבדה אינה מוכיחה שכל מקורות ההורדה נגישים.

ב־node03 נבדקה תקשורת ICMP ל־node01 ול־node02 ללא אובדן מנות (0%) ו־SSH פעיל. על node02 בדיקת `curl -k https://192.168.122.11:6443/livez` החזירה **HTTP 401 Unauthorized** — אישור לכך שה־API נגיש ברשת ומחייב אימות, לא תקלה בתקשורת. בדיקת `-k` שימשה לצורך בדיקת קישוריות בלבד.

## 3. התקנת השרת הראשון — node01

### יצירת תצורה

```bash
sudo mkdir -p /etc/rancher/k3s
sudo tee /etc/rancher/k3s/config.yaml >/dev/null <<'YAML'
cluster-init: true
node-ip: 192.168.122.11
tls-san:
  - 192.168.122.11
YAML
sudo chmod 600 /etc/rancher/k3s/config.yaml
```

- `cluster-init: true` — מאתחל קלאסטר חדש עם embedded etcd.
- `node-ip` — כתובת פנימית לפרסום השרת.
- `tls-san` — כולל את כתובת ה־API בתעודת TLS.
- קובץ `config.yaml` נשמר בהרשאות מצומצמות; kubeconfig נותר מוגן ל־root.

### התקנה — בוצעה

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
sudo install -o root -g root -m 700 /tmp/install-k3s.sh /root/install-k3s.sh
# לאחר עיון בתוכן סקריפט ההתקנה:
sudo sh /root/install-k3s.sh
```

**אימות שנצפה:**

```bash
sudo systemctl is-active k3s
sudo k3s --version
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A
```

השירות `active`; ‏`k3s-node01` במצב `Ready`, עם תפקיד `control-plane,etcd`; גרסת K3s `v1.37.2+k3s1`. נצפו `coredns`, ‏`metrics-server`, ‏`local-path-provisioner`, ‏`traefik`, ‏`svclb-traefik` במצב `Running`. עבודות `helm-install-*` במצב `Completed` — תקין.

> **שחזוריות:** מתקין node01 הופעל בלי `INSTALL_K3S_VERSION` מפורש; הגרסה המדויקת תועדה לאחר ההתקנה, ולשני השרתים הנוספים היא הוגדרה במפורש. בהרצות חדשות רצוי לקבע גרסה בכל שלושת השרתים מראש.

## 4. צירוף node02 ו־node03 — בוצע

### תצורת הצטרפות

בכל שרת מצטרף נוצר `/etc/rancher/k3s/config.yaml`. לדוגמה, node02:

```yaml
server: https://192.168.122.11:6443
node-ip: 192.168.122.12
token-file: /etc/rancher/k3s/server-token
tls-san:
  - 192.168.122.12
```

עבור node03 כתובת `node-ip` ו־`tls-san` היא `192.168.122.13`. **אין להגדיר `cluster-init: true` בשרת מצטרף.**

### העברת סוד ההצטרפות

הטוקן נלקח מ־`/var/lib/rancher/k3s/server/token` ב־node01, והועבר דרך SSH מוצפן מה־Ubuntu Laptop לקובץ `/etc/rancher/k3s/server-token` בשרתים האחרים. הוא **לא הוצג בצ'אט ולא נכנס לתיעוד או ל־Git**.

דוגמה מתועדת לשימוש חוזר **רק ממחשב המארח המורשה** (לא להציג את תוכן הסוד):

```bash
set -o pipefail
ssh zohargo@192.168.122.11 \
  'sudo cat /var/lib/rancher/k3s/server/token' \
  | ssh zohargo@192.168.122.12 \
  'sudo sh -c "umask 077; cat > /etc/rancher/k3s/server-token"'
```

ב־node03 מחליפים את היעד ל־`.13`. נבדקו `test -s` וההרשאות `600 root:root` עבור שני הקבצים. **אין להעתיק מפתח SSH פרטי בין השרתים.**

### התקנה כשרת K3s נוסף — בוצעה ב־node02 וב־node03

```bash
curl -sfL https://get.k3s.io -o /tmp/install-k3s.sh
sudo install -o root -g root -m 700 /tmp/install-k3s.sh /root/install-k3s.sh
sudo env INSTALL_K3S_VERSION='v1.37.2+k3s1' \
  INSTALL_K3S_EXEC='server' \
  sh /root/install-k3s.sh
```

**אימות סופי:** `sudo k3s kubectl get nodes -o wide` הציג שלושה שרתים ב־`Ready`, עם תפקידי `control-plane,etcd` וגרסה זהה. `sudo k3s kubectl get pods -A` הציג רכיבי מערכת פעילים ו־ServiceLB על שלוש המכונות.

## 5. Kubernetes API: Ready, kubeconfig ו־EndpointSlice

### מוכנות API — אומתה

```bash
sudo k3s kubectl get --raw='/readyz?verbose'
```

נצפו `[+]etcd ok`, ‏`[+]etcd-readiness ok`, ‏`[+]informer-sync ok`, ‏`[+]storage-readiness ok` ובסיום `readyz check passed`.

### קובץ kubeconfig והרשאות — מקרה שנפתר

`kubectl get no` ללא `sudo` נכשל עם `permission denied` בקריאת `/etc/rancher/k3s/k3s.yaml`. `sudo kubectl get no` או `sudo k3s kubectl get nodes` הצליחו. **לא שינינו את הרשאות kubeconfig ל־0644**, משום שהוא מאפשר גישת מנהל לקלאסטר. אפשר לתכנן בהמשך משתמש עם kubeconfig והרשאות RBAC מתאימות.

### EndpointSlice — אומת

```bash
sudo k3s kubectl get endpointslices -n default \
  -l kubernetes.io/service-name=kubernetes -o wide
```

תוצאה: `kubernetes`, פרוטוקול IPv4, פורט 6443, והכתובות `192.168.122.11`, ‏`.12`, ‏`.13`. פקודת `get endpoints` הישנה עבדה אך החזירה אזהרה שה־API הישן deprecated ב־Kubernetes 1.33 ומעלה. **EndpointSlice אינו מוכיח בפני עצמו בריאות etcd**.

## 6. גיבוי etcd לפני ניסוי HA — בוצע

על node03:

```bash
sudo k3s etcd-snapshot save --name pre-ha-test
sudo k3s etcd-snapshot ls
```

**תוצאת אמת:**

| שדה | ערך |
|---|---|
| Snapshot | `pre-ha-test-k3s-node03-1795023370` |
| Created | `2026-11-18T17:36:10Z` |
| Size | `11710496` bytes (כ־11.2 MiB) |
| Path | `/var/lib/rancher/k3s/server/db/snapshots/pre-ha-test-k3s-node03-1795023370` |
| Snapshot restore | **לא נוסה** |

`k3s etcd-snapshot ls` הציג אזהרות `Unknown flag --server/--node-ip/--token-file/--tls-san ... skipping`: אלו מאפייני שרת בקובץ התצורה שאינם נתמכים בפקודת Snapshot. הרשומה הופיעה למרות האזהרות.

בדיקת `sudo ls /.../pre-ha-test-*` נכשלה, ככל הנראה משום שה־glob הורחב על ידי shell לא־מורשה לפני `sudo`. בדיקה חלופית:

```bash
sudo find /var/lib/rancher/k3s/server/db/snapshots \
  -maxdepth 1 -type f -name 'pre-ha-test-*' -printf '%f | %s bytes\n'
```

**דיוק עובדתי:** התוצאה של `find` לא הועברה בשיחה, ולכן המסמך אינו מציג אותה כבדיקה שהושלמה. עצם הופעת ה־Snapshot ברשימת `k3s etcd-snapshot ls` כן אומתה. לשחזור נדרש גם **טוקן השרת המקורי**; יש לגבות אותו בנפרד באופן מוצפן ומאובטח. Snapshot של etcd מכיל משאבי API, אך אינו מגבה נתוני PVC, קבצים של אפליקציות או את מחשב המארח.

## 7. בדיקות ישירות של etcd — בוצעו

ב־node03:

```bash
apt-cache policy etcd-client
sudo apt update
sudo apt install -y etcd-client
etcdctl version
```

נצפתה גרסת לקוח `etcdctl 3.4.30`, ‏API v3; בצד שרת נצפתה גרסת etcd `3.7.1`. בדיקות הקריאה והבריאות הצליחו למרות פער הגרסאות. אין להסיק מכך תאימות מלאה לכל פעולות הניהול.

### נתיבי TLS — אומתו, בלי לחשוף מפתחות

```text
/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt
/var/lib/rancher/k3s/server/tls/etcd/client.crt
/var/lib/rancher/k3s/server/tls/etcd/client.key
```

### פקודות בדיקה חוזרות — לקריאה ולבריאות בלבד

```bash
# ב-node03; הגדרת משתני סביבת shell מקומית לשיפור קריאות
ETCD_TLS=/var/lib/rancher/k3s/server/tls/etcd

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  member list -w table

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  endpoint status --cluster -w table

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert="$ETCD_TLS/server-ca.crt" \
  --cert="$ETCD_TLS/client.crt" \
  --key="$ETCD_TLS/client.key" \
  endpoint health --cluster -w table
```

### תוצאות שהתקבלו — לפני הכשל

| Member | ID | Peer URL | Client URL | Started | Learner | Leader |
|---|---|---|---|---|---|---|
| node01 | `69d968bf93159205` | `https://192.168.122.11:2380` | `https://192.168.122.11:2379` | yes | false | **true** |
| node02 | `82c559eb04bcdb0c` | `https://192.168.122.12:2380` | `https://192.168.122.12:2379` | yes | false | false |
| node03 | `a26fd1aaed44a2dc` | `https://192.168.122.13:2380` | `https://192.168.122.13:2379` | yes | false | false |

כל שלושת החברים היו בעלי זכות הצבעה (`IS LEARNER=false`). ב־`endpoint status --cluster`: גרסה `3.7.1`, ‏DB בגודל כ־12MB, ‏`RAFT TERM=2`, ללא שגיאות; `RAFT INDEX` 13837 ב־node01 ו־13838 ב־node02/03 באותה מדידה (הבדל זעיר בזמן בדיקות לא אטומיות אינו כשלעצמו תקלה). `endpoint health --cluster` החזיר `HEALTH=true` בכל השלושה, עם זמני תגובה 3.67ms, ‏4.13ms ו־4.44ms בהתאמה.

**הבהרה:** `endpoint health` מבצע בדיקת התחייבות proposal; זו אינה פקודת צפייה בלבד במובן המוחלט, אך אינה משנה את חברות הקלאסטר או את תצורתו.

## 8. ניסוי HA ראשון — עצירת Follower node02 והחזרה

### יעד ותנאי פתיחה

- שלושה חברי etcd בריאים ומצב `Ready` ב־Kubernetes.
- Snapshot בשם `pre-ha-test` הופיע ברשימת הגיבויים.
- **Leader לפני הניסוי:** node01. **Follower שנבחר לניסוי:** node02.
- לפני העצירה נבדקו Pods על node02: רק `kube-system/svclb-traefik-18dce389-jsdzj`, במצב `2/2 Running`. לא נפרסו עדיין יישומי משתמש או MongoDB.
- הפעולה משפיעה בפועל על K3s ועל Workloads מקומיים; מבצעים אותה רק בסביבה שבה השבתה מותרת.

### א. עצירה ב־node02 — בוצעה

```bash
# התחברות ל-node02 מהמארח
ssh zohargo@192.168.122.12
hostname # חייב להחזיר k3s-node02
sudo systemctl stop k3s
sudo systemctl is-active k3s
```

עצירת `systemctl stop k3s` אינה כיבוי VM ואינה מחיקה של נתוני etcd. לא הורץ `k3s-killall.sh`.

### ב. בדיקות בתקופת הכשל מ־node03 — בוצעו

```bash
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get --raw='/readyz'

sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://192.168.122.11:2379,https://192.168.122.13:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health -w table
```

**תוצאות שנצפו:** node01 `Ready`, ‏node02 `NotReady`, ‏node03 `Ready`. API `/readyz` החזיר `ok`. ב־etcd: ‏node01 `HEALTH=true` ב־4.726607ms; ‏node03 `HEALTH=true` ב־4.78308ms. כלומר ה־API על node03 נשאר זמין וקוורום Raft של 2/3 המשיך לבצע פעולות בהצלחה.

### ג. התאוששות — בוצעה

```bash
# ב-node02
sudo systemctl start k3s
sudo systemctl is-active k3s

# ב-node03
sudo k3s kubectl get nodes -o wide
sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health --cluster -w table
```

**תוצאות שנצפו לאחר החזרה:** שלושת השרתים `Ready`; שלושת חברי etcd שוב `HEALTH=true`: ‏node01 ‏5.452142ms, ‏node02 ‏4.625058ms, ‏node03 ‏4.673714ms. **ניסוי Follower failure + recovery הושלם בהצלחה.**

### מה מוכיח הניסוי — ומה לא

| נבדק בהצלחה | לא נבדק עדיין |
|---|---|
| אובדן זמני של חבר etcd מצביע אחד | השבתת Raft Leader ובחירה מחדש |
| שמירת quorum 2 מתוך 3 | כשל של שתי מכונות במקביל |
| זמינות API ב־node03 בזמן הכשל | זמינות רציפה של endpoint API יחיד ומאוזן |
| חזרה ל־Ready ול־etcd Healthy לאחר recovery | רציפות עסקית של אפליקציה/DB בזמן כשל |
| Snapshot נוצר ונרשם לפני הניסוי | שחזור Snapshot בהצלחה |

**מגבלה משמעותית:** כלל המכונות הווירטואליות נמצאות על מחשב מארח אחד; הקלאסטר אינו מוגן מכשל חשמל, SSD, מחשב מארח או גשר הרשת המקומי שלו.

## 9. Lessons Learned / Troubleshooting

1. **Permission denied בהתחברות SSH משרת לשרת:** מפתח ה־SSH הפרטי קיים במחשב המארח בלבד. חזרנו למארח והתחברנו ממנו לשרת היעד. אין סיבה לשכפל מפתחות פרטיים בין שרתי הקלאסטר.
2. **HTTP 401 מול API ללא הזדהות:** TCP/TLS הגיע לשרת; הבקשה נדחתה בשל היעדר אישור. זו אינה הוכחה שהשרת אינו נגיש.
3. **`kubectl` ללא `sudo` נכשל:** ה־kubeconfig ב־`/etc/rancher/k3s/k3s.yaml` מוגן. לא מומלץ לשנות הרשאות ל־0644.
4. **אזהרת Endpoints deprecated:** השתמשנו ב־`EndpointSlice` במקום ב־`v1 Endpoints`.
5. **אזהרות `Unknown flag` בפלט Snapshot:** הפקודה דילגה על פרמטרי `config.yaml` שאינם רלוונטיים; ה־Snapshot הופיע ברשימת הגיבויים.
6. **גלוב מול `sudo ls`:** הרחבת `*` עלולה להיכשל כשה־shell הנוכחי אינו יכול לקרוא תיקייה מוגנת; `sudo find` נותן דרך בטוחה יותר לבדוק קיום קובץ.
7. **בדיקת etcd ישירה חשובה:** `kubectl get nodes` אינו תחליף ל־`member list`, ‏`endpoint status` ו־`endpoint health`.
8. **גרסאות etcdctl ושרת שונות:** פעולות הבדיקה עבדו עם לקוח 3.4.30 מול שרת 3.7.1, אך לא נוסו פקודות ניהול/שינוי מורכבות.
9. **ראיית HA צריכה להיות מוגדרת:** ניסוי Follower הצליח, אך אין להסיק ממנו שכל סוגי הכשל מכוסים.

## 10. פקודות Health Check שוטפות

```bash
# מכל אחד משלושת שרתי K3s
sudo systemctl is-active k3s
sudo k3s --version
sudo k3s kubectl get nodes -o wide
sudo k3s kubectl get pods -A -o wide
sudo k3s kubectl get --raw='/readyz?verbose'
sudo k3s kubectl get endpointslices -n default \
  -l kubernetes.io/service-name=kubernetes -o wide
sudo k3s etcd-snapshot ls

# על node03 לאחר התקנת etcd-client: בדיקות הצבעה/בריאות
sudo env ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/var/lib/rancher/k3s/server/tls/etcd/server-ca.crt \
  --cert=/var/lib/rancher/k3s/server/tls/etcd/client.crt \
  --key=/var/lib/rancher/k3s/server/tls/etcd/client.key \
  endpoint health --cluster -w table
```

## 11. נושאים פתוחים והמשך העבודה

| עדיפות | משימה | מצב |
|---|---|---|
| גבוהה | גיבוי טוקן השרת באופן מאובטח והעתקת Snapshot אל מחוץ למחשב המארח | לא בוצע |
| גבוהה | תכנון כתובת יציבה ל־Kubernetes API באמצעות Load Balancer/‏VIP והתאמת TLS SANs | לא בוצע |
| בינונית | ניסוי נפילת Leader **רק לאחר תכנון rollback ובדיקת סביבה** | לא בוצע |
| בינונית | תרגול שחזור etcd בתנאי מעבדה מבודדים | לא בוצע |
| הבאה בתרגיל | לבדוק Helm, לבחור Chart Bitnami תואם ולוודא MongoDB `8.0.13` לפני התקנה | לא בוצע |
| הבאה בתרגיל | ליצור Namespace ו־values.yaml הכוללים Requests/Limits, ‏NodePort, Metrics ו־Persistence כבוי | לא בוצע |
| עתידית | Argo CD, GitOps, אפליקציה, GitHub Actions, ‏SAST, ‏Trivy חסימת HIGH | לא בוצע |

## 12. מקורות לתיעוד טכני

- K3s HA embedded etcd: https://docs.k3s.io/datastore/ha-embedded
- K3s installation: https://docs.k3s.io/installation
- K3s datastore backup and restore: https://docs.k3s.io/datastore/backup-restore
- K3s etcd snapshots: https://docs.k3s.io/cli/etcd-snapshot
- etcd cluster checks: https://etcd.io/docs/v3.5/tutorials/how-to-check-cluster-status/

---

**כללי בטיחות ותיעוד:** אין להעלות ל־Git קובצי kubeconfig בעלי הרשאות ניהול, טוקן הצטרפות, מפתחות SSH פרטיים, מפתחות TLS, Secrets או Snapshots של etcd. בעת חזרה על הניסוי, יש לבדוק קודם את ה־Leader הנוכחי, Pods חשובים, מצב הגיבוי וזמינות שני השרתים האחרים. אין להריץ פקודות מחיקת datastore, ‏`cluster-reset` או `k3s-killall.sh` כחלק מניסוי הפסקת שירות רגיל.
