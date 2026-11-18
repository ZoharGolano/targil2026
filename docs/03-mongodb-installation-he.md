# 03 — התקנת MongoDB 8.0.13 באמצעות Helm על K3s

פרויקט: **Targil2026**  
תאריך ביצוע: **18 בנובמבר 2026**  
סביבה: מעבדת K3s על שלוש מכונות וירטואליות, Ubuntu 24.04; K3s ב־HA עם embedded etcd.

> **ייעוד:** תיעוד מעבדה ולמידה. התצורה אינה מומלצת ל־Production משום שה־MongoDB פועל ב־Standalone, ללא Persistence, ומשתמש בתמונות Bitnami Legacy ללא עדכוני אבטחה שוטפים.

## 1. מטרות והחלטות תכנון

| נושא | בחירה | הסבר |
|---|---|---|
| Helm Chart | `bitnami/mongodb` גרסה `16.5.45` | גרסה קבועה המצהירה על MongoDB 8.0.13 |
| MongoDB | `8.0.13` | דרישת התרגיל; אומת מתוך ה־Container |
| Architecture | `standalone` | התקנה פשוטה ללמידה; ללא HA ברמת המסד |
| Namespace | `mongodb` | הפרדת משאבים לוגית; אינה מספקת בידוד רשת אוטומטי |
| Persistence | `false` | דרישת התרגיל; מידע יאבד בעת החלפת Pod |
| Authentication | Enabled; Secret קיים | הסיסמה אינה ב־values.yaml או ב־Git |
| Service | `NodePort` בפורט `32017` | בדיקת גישה מהמחשב המארח |
| Metrics | MongoDB Exporter, פורט `9216` | מאפשר בדיקת `/metrics` ושילוב עתידי עם Prometheus |
| Images | `bitnamilegacy/mongodb` ו־`bitnamilegacy/mongodb-exporter` | שימוש לימודי בלבד; אין עדכוני אבטחה שוטפים |

## 2. תשתית

הקלאסטר כולל שלושה שרתי K3s, המשמשים גם כ־Control Plane וגם כ־Workers, ברשת NAT של libvirt:

| Node | IP |
|---|---|
| `k3s-node01` | `192.168.122.11` |
| `k3s-node02` | `192.168.122.12` |
| `k3s-node03` | `192.168.122.13` |

ההתקנה בוצעה מ־`k3s-node03`, וה־Pod שובץ ל־`k3s-node03` עם IP `10.42.2.3` בזמן הבדיקה. זוהי כתובת דינמית שעשויה להשתנות.

## 3. גרסת Helm וה־Chart

```bash
helm version
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update
helm search repo bitnami/mongodb --versions | grep '8.0.13'
helm show chart bitnami/mongodb --version 16.5.45
helm show values bitnami/mongodb --version 16.5.45 > default-values.yaml
```

נמצאה ההתאמה:

```text
bitnami/mongodb    16.5.45    8.0.13
```

**הערה:** גרסת ה־Chart אינה תמיד זהה לגרסת התוכנה. `appVersion: 8.0.13` אינה בדיקה מספקת כשלעצמה — נדרש אימות מתוך ה־Container.

## 4. קובץ הגדרות Helm

קובץ העבודה: `kubernetes/mongodb/values.yaml`. יש להשתמש בקובץ המקורי ששימש להתקנה; התצורה הבאה היא תיעוד תמציתי של ההגדרות שבחרנו:

```yaml
# Targil2026 lab-only configuration
global:
  security:
    allowInsecureImages: true
architecture: standalone
image:
  registry: docker.io
  repository: bitnamilegacy/mongodb
  tag: 8.0.13-debian-12-r0
auth:
  enabled: true
  existingSecret: mongodb-credentials
persistence:
  enabled: false
service:
  type: NodePort
  ports:
    mongodb: 27017
  nodePorts:
    mongodb: 32017
resources:
  requests:
    cpu: 250m
    memory: 512Mi
  limits:
    cpu: 1000m
    memory: 2Gi
metrics:
  enabled: true
  image:
    registry: docker.io
    repository: bitnamilegacy/mongodb-exporter
    tag: 0.47.0-debian-12-r1
  resources:
    requests:
      cpu: 50m
      memory: 64Mi
    limits:
      cpu: 200m
      memory: 256Mi
```

`global.security.allowInsecureImages: true` עוקף בדיקת מקור תמונות של ה־Chart. זו **חריגת אבטחה ייעודית למעבדה**; אין להעתיק אותה אוטומטית ל־Production.

## 5. בדיקת מניפסטים לפני התקנה

```bash
helm template mongodb bitnami/mongodb \
  --version 16.5.45 --namespace mongodb \
  -f values.yaml > rendered.yaml

grep '^kind:' rendered.yaml
grep 'image:' rendered.yaml
```

נוצרו: `NetworkPolicy`, `PodDisruptionBudget`, `ServiceAccount`, `ConfigMap`, שני `Service` ומשאב `Deployment`.

תמונות שהופיעו ב־render:

```text
docker.io/bitnamilegacy/mongodb:8.0.13-debian-12-r0
docker.io/bitnamilegacy/mongodb-exporter:0.47.0-debian-12-r1
```

`rendered.yaml` הוא קובץ שנוצר אוטומטית. יש לבדוק מידע רגיש לפני שיתוף שלו; אין הכרח לשמור אותו ב־Git.

## 6. Namespace ו־Secret

```bash
sudo k3s kubectl create namespace mongodb
```

יצירת Secret **ללא שמירת סיסמה ב־Git או בהיסטוריית פקודות**:

```bash
PASSWORD="$(openssl rand -hex 24)"
printf '%s' "$PASSWORD" | \
  sudo k3s kubectl -n mongodb create secret generic mongodb-credentials \
    --from-file=mongodb-root-password=/dev/stdin
unset PASSWORD
```

> אם ה־Secret כבר קיים, **אין להריץ את פקודת היצירה מחדש**. סיסמה חדשה שלא מסונכרנת עם האתחול הקיים עשויה לשבור אימות.

בדיקה שאינה חושפת סיסמה:

```bash
sudo k3s kubectl -n mongodb get secret mongodb-credentials \
  -o jsonpath='{.data.mongodb-root-password}' | base64 -d | wc -c
```

בתהליך שתועד התקבלו **48 bytes**. שדה הסוד הוא `mongodb-root-password`.

## 7. התקנה

בהרצה הראשונה התקבלה השגיאה:

```text
Error: INSTALLATION FAILED: repo bitnami not found
```

הסיבה: ה־Repository נוסף עבור משתמש `zohargo`, בעוד שהתקנת Helm בוצעה עם `sudo` (לכן Helm השתמש בהגדרות `root`). תיקון:

```bash
sudo helm repo add bitnami https://charts.bitnami.com/bitnami
sudo helm repo update
sudo helm show chart bitnami/mongodb --version 16.5.45
```

ההתקנה שבוצעה בהצלחה:

```bash
sudo env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  helm install mongodb bitnami/mongodb \
  --version 16.5.45 \
  --namespace mongodb \
  --values values.yaml \
  --wait --timeout 5m
```

Helm דיווח: `STATUS: deployed`, `REVISION: 1`, `CHART: mongodb-16.5.45`, `APP VERSION: 8.0.13`.

**שיפור לעתיד:** לנהל kubeconfig והרשאות מוגבלות במחשב המארח ולהימנע מעבודה שוטפת עם `sudo helm`. אין להעתיק kubeconfig עם הרשאות מנהל ל־Git.

## 8. תוצאות הבדיקות

### 8.1 Pods ושירותים

```bash
sudo k3s kubectl get pods -n mongodb -o wide
sudo k3s kubectl get svc -n mongodb
```

תוצאות שנצפו:

```text
mongodb-549c7d7475-hrt6d   2/2 Running   0 restarts   10.42.2.3   k3s-node03
mongodb           NodePort    10.43.196.248   27017:32017/TCP
mongodb-metrics   ClusterIP   10.43.131.98    9216/TCP
```

### 8.2 אימות גרסה אמיתית

```bash
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- mongod --version
```

תוצאה: `db version v8.0.13`.

### 8.3 Authentication — תקלה ופתרון

ניסיון להעביר `"$MONGODB_ROOT_PASSWORD"` ל־`mongosh` נכשל עם `Authentication failed` משום שהמשתנה **לא הוגדר**. בפועל ה־Chart השתמש ב־File-Based Secret: המשתנה `MONGODB_ROOT_PASSWORD_FILE` הוגדר.

פקודת אימות שהצליחה:

```bash
sudo k3s kubectl -n mongodb exec deploy/mongodb -c mongodb -- bash -c '
  mongosh --quiet --host 127.0.0.1 \
    --username "$MONGODB_ROOT_USER" \
    --password "$(cat "$MONGODB_ROOT_PASSWORD_FILE")" \
    --authenticationDatabase admin \
    --eval "db.adminCommand({ping: 1})"
'
```

תוצאה:

```javascript
{ ok: 1 }
```

**הערת אבטחה:** העברת סיסמה בארגומנטים (`--password`) עשויה לחשוף אותה זמנית ברשימת תהליכים בתוך ה־Container. זו פקודת אימות למעבדה, לא דוגמה אידיאלית לטיפול בסודות ב־Production.

### 8.4 NodePort מהמחשב המארח

```bash
nc -vz -w 5 192.168.122.13 32017
```

תוצאה:

```text
Connection to 192.168.122.13 32017 port [tcp/*] succeeded!
```

זו בדיקת **קישוריות TCP**, לא בדיקת Authentication חיצונית. הוגדר `externalTrafficPolicy: Local`, ולכן הגישה נבדקה ל־Node שבו רץ ה־Pod; ייתכן שלא תהיה נגישות זהה מכל Node.

### 8.5 Exporter ו־Metrics

```bash
sudo k3s kubectl -n mongodb port-forward svc/mongodb-metrics 9216:9216
# בטרמינל אחר על אותו שרת:
curl -fsS http://127.0.0.1:9216/metrics | grep '^mongodb_up'
```

תוצאה:

```text
mongodb_up{cluster_role="mongod"} 1
```

נצפו גם המדדים `mongodb_ss_connections` (למשל `current=3`, `active=1` בזמן הבדיקה). הבדיקה **אינה מוכיחה** ש־Prometheus כבר סורק את ה־Exporter — רק שהוא פועל ומתקשר עם MongoDB.

### 8.6 Resources בפועל

```bash
sudo k3s kubectl -n mongodb get deployment mongodb \
  -o jsonpath='{range .spec.template.spec.containers[*]}Container: {.name}{"\n"}Requests: {.resources.requests}{"\n"}Limits: {.resources.limits}{"\n\n"}{end}'
sudo k3s kubectl top pod -n mongodb --containers
```

| Container | CPU request | CPU limit | Memory request | Memory limit | CPU נצפה | Memory נצפה |
|---|---:|---:|---:|---:|---:|---:|
| mongodb | 250m | 1 core | 512Mi | 2Gi | 90m | 89Mi |
| metrics | 50m | 200m | 64Mi | 256Mi | 1m | 11Mi |

הנתונים הנצפים הם **צילום מצב נקודתי**, לא ממוצע/שיא צריכה.

### 8.7 Persistence

```bash
sudo k3s kubectl get pvc -n mongodb
```

תוצאה: `No resources found in mongodb namespace.` בנוסף הוגדר `persistence.enabled: false`; לכן לא נוצר PVC עבור MongoDB בתצורה זו.

## 9. אבטחת רשת

ה־Chart יצר `NetworkPolicy` עם `policyTypes: [Ingress, Egress]`, `egress: - {}` וכללי Ingress המאפשרים את הפורטים `27017` ו־`9216` **ללא `from`**. לפיכך, המדיניות אינה מגבילה מקורות גישה לפורטים האלה. יש להגן על ה־NodePort ברשת ובחומת האש ולבחון הגבלת מקורות, לרבות התנהגות ה־CNI וה־NodePort בפועל.

הערה: `NetworkPolicy` ו־`Namespace` אינם מחליפים Firewall ואינם מבטיחים לבדם בידוד גישה חיצונית.

## 10. מגבלות וסיכונים

1. **Standalone:** אין Replica Set, ולכן אין HA ברמת MongoDB.
2. **ללא Persistence:** מחיקה/החלפה של Pod עלולה לגרום לאובדן נתונים.
3. **Bitnami Legacy:** התמונות אינן מקבלות עדכוני אבטחה שוטפים; Helm הזהיר גם מפני החלפת תמונות ומעקף בדיקת המקור שלהן.
4. **NodePort:** פותח נתיב גישה לרשת המעבדה; אין להניח שהגישה מוגבלת אוטומטית.
5. **Secrets:** יש להימנע משמירת סיסמאות ב־Git, Shell history, תיעוד או צילומי מסך.
6. **Metrics:** Exporter פעיל, אך טרם אומת Scraping אוטומטי של Prometheus.

## 11. קבצים לשמירה ב־Git

מומלץ לשמור:

```text
kubernetes/mongodb/values.yaml
docs/03-mongodb-installation-he.md
```

`default-values.yaml` הוא עותק של ערכי ה־Chart, ו־`rendered.yaml` הוא תוצר של `helm template`; הם אינם הכרחיים למאגר. **אין לשמור Secrets, kubeconfig, tokens או סיסמאות.**

### בדיקות לפני Commit

```bash
cd ~/targil2026
git status --short
git diff --no-index /dev/null kubernetes/mongodb/values.yaml || true
# בודקים ידנית שלא הופיעו סיסמאות או נתונים רגישים
```

לאחר הבדיקה, יש להוסיף רק את הקבצים שאושרו:

```bash
git add kubernetes/mongodb/values.yaml docs/03-mongodb-installation-he.md
git diff --cached --stat
git diff --cached --check
git commit -m "Document MongoDB 8.0.13 Helm deployment and validation"
```

> אם במאגר טרם בוצע Commit ראשון, הוא ייווצר בפקודה הזו. `git push` דורש לוודא קודם שה־Remote ושם הענף נכונים.

## 12. השלבים הבאים

- בדיקת חיבור `mongosh` מלא דרך ה־NodePort מהמחשב המארח (עד כה הוכחה קישוריות TCP בלבד).
- שקילת הידוק NetworkPolicy ו־Firewall בהתאם לצורכי המעבדה.
- התקנת האפליקציה הנדרשת בתרגיל, Helm Chart שלה, ובהמשך Argo CD ו־GitHub Actions עם בדיקות SAST ו־Trivy.
