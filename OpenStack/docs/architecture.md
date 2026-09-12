# Arhitektura IRUO Moodle okoline na OpenStacku

## 1. Uvod, cilj i opseg

### 1.1 Sažetak

Ovaj dokument opisuje stvarnu arhitekturu Terraform implementacije za IRUO Moodle testne okoline na OpenStacku. Za svakog korisnika s ulogom `developer` stvara se odvojeni Keystone projekt, privatna mreža, router, dvije aplikacijske virtualne instance, samostalna MariaDB virtualna instanca i pet lokalnih Cinder volumena. Zajednički projekt sadrži Jump i Lead instancu te administracijsku mrežu.

Arhitektura je namjerno podijeljena u Terraform rootove i module. Stanja su odvojena, primjena je sekvencijalna, a pristup gostima ide preko jedine floating IP adrese dodijeljene Jump instanci. Dokument je samostalan tehnički opis: vrijednosti lozinki, privatnih ključeva, stvarnih identifikatora i drugih osjetljivih podataka nisu navedene.

### 1.2 Ciljevi

Ciljevi rješenja su:

- reproducibilno stvaranje shared i developer OpenStack projekata;
- izolacija svakog developera vlastitim projektom, mrežom i podacima;
- centralizirani administrativni ulaz preko Jump instance i Lead operativne instance;
- automatizirano postavljanje Rocky Linuxa, Moodlea, Apachea, PHP-FPM-a i MariaDB-a;
- eksplicitno upravljanje Terraform stanjima, redoslijedom i preduvjetima;
- jasno dokumentiranje činjenice da aplikacijski Moodle dataroot nije dijeljen između app instanci.

### 1.3 Opseg i pretpostavke

Terraform rootovi i moduli nalaze se unutar direktorija `OpenStack/`. Operatorski CSV očekuje se kao `config/users.csv`, a skripta `scripts/render-terraform-inputs.py` iz njega izrađuje tipizirane JSON ulaze. Implementacija je vezana uz OpenStack regiju `regionOne`, Terraform `>= 1.8.0` i OpenStack provider `terraform-provider-openstack/openstack` točno verzije `3.4.0`.

Postojeća vanjska mreža dohvaća se po nazivu `provider-datacentre` ako se naziv ne nadjača ulazom. Zadani Cinder tip je `tripleo`, zadani naziv deploymenta je `iruo-lab`, a zadani Swift container za Terraform state je `iruo-terraform-state`. Ovaj opis ne pretpostavlja uspješno live izvođenje; činjenice su izvedene iz ciljnog koda i predložaka.

## 2. Pregled arhitekture

### 2.1 Slojevi rješenja

Implementacija ima četiri Terraform roota i tri reusable modula:

- `bootstrap` stvara Keystone projekte, korisnike, grupe, role, lozinke i flavor resurse;
- `roots/shared` poziva `modules/platform` i stvara shared administracijsku osnovu, Jump i Lead;
- `roots/developer` poziva `modules/workspace` jednom za svaki developer Terraform workspace;
- `roots/shared-reconcile` poziva `modules/access-links` i naknadno povezuje Jump na privatne developerske mreže;
- `modules/platform` opisuje shared mrežu, sigurnosne grupe, portove, instance, Nova keypair i floating IP;
- `modules/workspace` opisuje developersku mrežu, router, RBAC, load balancer, instance i Cinder resurse;
- `modules/access-links` opisuje portove na developerskim mrežama i attachment tih portova na postojeći Jump.

### 2.2 Glavni topološki dijagram

```text
                                      POSTOJEĆA VANJSKA MREŽA
                                      provider-datacentre
                                                |
                 +------------------------------+------------------------------+
                 |                                                             |
          SHARED PROJEKT                                             DEVELOPER PROJEKT
          iruo-lab-shared                                            iruo-lab-<slug>
                 |                                                             |
       iruo-lab-admin-router                                  iruo-lab-<slug>-router
        gateway + SNAT                                       gateway + SNAT
                 |                                                             |
        10.200.0.0/24                              10.210.<slot>.0/24
        .1 router gateway                           .1 router gateway
        .10 Jump ---- floating IP                   .5 Jump management NIC
        .20 Lead                                      .10 app01 ----+
           |                                          .11 app02 ----+-- OVN LB VIP .50:80
           +-- portovi za developere                  .20 DB VM
                                                      .50 VIP

  Jump management port (.5) -- Neutron RBAC access_as_shared --> developer network
  Jump management port (.5) -- compute interface attachment --> postojeći Jump VM
```

Slika 1: Logička topologija shared projekta i jedne developerske okoline.

Shared projekt dobiva jedan Jump i jedan Lead. Developerski projekt dobiva vlastiti router i subnet. Neutron RBAC politika `access_as_shared` dopušta shared projektu pristup developerskoj mreži, nakon čega `shared-reconcile` stvara port s adresom `.5` i spaja ga na Jump. Samo Jump dobiva floating IP; developerske instance i Lead nemaju floating IP resurs.

### 2.3 Resursni obuhvat po developeru

Svaki developerov workspace sadrži jednu privatnu mrežu i subnet, jedan router, RBAC politiku prema shared projektu, dvije security grupe, dva app porta, jedan DB port, OVN load balancer s listenerom, poolom i dva člana, pet lokalnih Cinder volumena, dvije app instance i jednu DB instancu. Shared reconcile dodatno stvara management port za taj subnet i attachment na Jump.

## 3. Terraform rootovi, moduli i stanje

### 3.1 Rootovi i moduli

| Root ili modul | Odgovornost | Opseg providera ili pozivatelj |
| --- | --- | --- |
| `bootstrap` | Keystone projekti, korisnici, grupe, role, lozinke i javni Nova flavori | administratorski OpenStack provider |
| `roots/shared` | shared root koji poziva platformu | provider ograničen na shared projekt |
| `modules/platform` | admin mreža/subnet/router, Jump i Lead, security grupe, keypair i Jump floating IP | poziva ga `roots/shared` |
| `roots/developer` | jedan workspace po developeru | provider ograničen na developer projekt |
| `modules/workspace` | tenant mreža, router, RBAC, OVN LB, VM-ovi i Cinder | poziva ga `roots/developer` |
| `roots/shared-reconcile` | čita shared i developer stateove | provider ograničen na shared projekt |
| `modules/access-links` | Jump management portovi i interface attachmenti | poziva ga `roots/shared-reconcile` |

Tablica 1: Terraform rootovi, moduli i njihove odgovornosti.

`bootstrap` koristi administratorski opseg jer stvara Keystone identitete i projekte. `roots/shared` iz bootstrap statea čita shared projekt, flavor i korisničke podatke, a `roots/developer` iz bootstrap i shared statea čita developer projekt, network slot, keypair, vanjsku mrežu i Lead javni ključ. `shared-reconcile` iz shared i svakog developer statea čita podatke potrebne za management portove.

### 3.2 Remote state i workspace ključevi

Sva četiri roota koriste Terraform S3 backend konfiguriran za Swift S3-kompatibilni API. Backend datoteke se generiraju u runtime direktoriju, koriste path-style adresiranje i kompatibilne `skip_*` postavke. Container je `iruo-terraform-state` prema zadanoj konfiguraciji.

| Root | Terraform workspace | State objekt |
| --- | --- | --- |
| `bootstrap` | `default` | `bootstrap.tfstate` |
| `roots/shared` | `default` | `shared.tfstate` |
| `roots/developer` | `<developer-slug>` | `developer/<developer-slug>/developer.tfstate` |
| `roots/shared-reconcile` | `default` | `shared-reconcile.tfstate` |

Tablica 2: Remote-state objekti i workspace ugovori.

Ugovori između stanja su eksplicitni: shared čita `bootstrap.tfstate`; developer čita `bootstrap.tfstate` i `shared.tfstate`; reconcile čita `shared.tfstate` i stanje svakog developer workspacea. Rootovi koji predstavljaju fiksne state objekte odbijaju svaki workspace osim `default`. Developer root prihvaća samo workspace koji je jednak `var.developer.slug` i nije `default`.

Swift S3 backend ne tvrdi niti pretpostavlja lockfile ili conditional-lock semantiku. Operacije nad istim state objektom ne smiju se izvoditi istodobno. `run.sh` developer workspaceove zato obrađuje sekvencijalno prema redoslijedu iz CSV-a.

### 3.3 Preduvjeti i zaštitne provjere

Prije stvaranja OpenStack resursa `terraform_data` precondition provjere:

- `bootstrap` zahtijeva `default` workspace i jedinstvene network slotove;
- developer slugovi moraju biti valjani, a slug `default` je rezerviran;
- shared i bootstrap state moraju imati isti `name_seed` i isti shared project ID;
- `shared-reconcile` provjerava da ključevi tenant mape odgovaraju slugovima i da su identiteti i CIDR-ovi jedinstveni.

Network slot se za developer slug računa formulom:

```text
slot = parseint(substr(sha256(slug), 0, 8), 16) % 64
```

Rezultat je cijeli broj od 0 do 63. Terraform guard odbija koliziju prije stvaranja tenant resursa.

### 3.4 Redoslijed apply i destroy

```text
APPLY
  bootstrap
      |
      v
  roots/shared
      |
      v
  roots/developer: <slug-1>, zatim <slug-2>, ...
      |
      v
  roots/shared-reconcile

DESTROY
  roots/shared-reconcile
      |
      v
  roots/developer: svaki postojeći developer workspace
      |
      v
  roots/shared
      |
      v
  bootstrap
```

Slika 2: Propisani redoslijed primjene i obrnuti redoslijed rušenja rootova.

`destroy.sh` prije destroy operacije radi `apply -refresh-only`, prepoznaje dijagnostike za resurse koji su nestali iz OpenStacka i po potrebi uklanja njihove adrese iz statea. Reconciliation i destroy imaju najviše 50 pokušaja po rootu. Nakon uspješnog rušenja developer statea briše se njegov Terraform workspace. State container, EC2 credentials i Rocky image nisu dio tog destroy opsega.

## 4. Identiteti, projekti, uloge i flavori

### 4.1 Projekti i korisnici

`bootstrap` stvara shared projekt `${name_seed}-shared` i po jedan developer projekt `${name_seed}-${slug}`. Za svaki CSV zapis stvara korisnika `usr-${name_seed}-${slug}`. `devops_lead` ima shared projekt kao `default_project_id`, a developer ima vlastiti projekt. Svaki developer dobiva vlastitu grupu `grp-${name_seed}-${slug}`, dok Lead dobiva grupu `grp-${name_seed}-leads`.

Developer grupa dobiva standardnu Keystone ulogu `member` na vlastitom projektu. Lead grupa dobiva `member` na shared i svim developer projektima. `provisioner_user_id`, izveden iz trenutačnog administratorskog identiteta, dobiva standardnu ulogu `admin` na shared i svim developer projektima. Implementacija ne stvara prilagođenu Keystone ulogu.

### 4.2 Flavouri

| Logička oznaka | Naziv | vCPU | RAM | Root disk |
| --- | --- | ---: | ---: | ---: |
| `shared` | `flv-techsprint-lab-small` | 1 | 2048 MiB | 10 GB |
| `app` | `flv-techsprint-app` | 2 | 4096 MiB | 10 GB |
| `database` | `flv-techsprint-db` | 2 | 4096 MiB | 10 GB |

Tablica 3: Javni Nova flavori koje `bootstrap` prema zadanim vrijednostima stvara.

Jump i Lead koriste `flavor_ids.shared`. Developer root prema zadanim vrijednostima također koristi `flavor_ids.shared` za app i DB; zaseban app ili DB flavor može se proslijediti ulazom. Zato sama logička imena `app` i `database` ne znače da se ta dva flavor resursa automatski koriste.

### 4.3 Nazivi i stabilni identiteti

`name_seed` je deployment-wide prefiks. Mora imati 4–32 znaka, početi malim ASCII slovom i sadržavati samo mala slova, znamenke i crtice. Ako bootstrap state već postoji, `run.sh` koristi kanonski spremljeni `name_seed` i odbija drukčiju vrijednost iz okoline. Prazan bootstrap state dobiva `iruo-lab`, osim ako je postavljen `TECHSPRINT_NAME_SEED`.

CSV parser prihvaća hrvatska ili kanonska zaglavlja i delimiter `;` ili `,`. Ime i prezime transliteriraju se u deterministički ASCII slug. Potreban je točno jedan `devops_lead` i najmanje dva `developer` zapisa. Email je opcionalan u CSV-u; ako nedostaje, renderer generira sintaktički valjan primjer domene `example.invalid`.

## 5. Mrežni plan

### 5.1 Vanjska i shared administracijska mreža

`modules/platform` dohvaća postojeću external mrežu po `external_network_name`, stvara admin mrežu i subnet `10.200.0.0/24`, uključuje DHCP i objavljuje DNS poslužitelje `1.1.1.1` i `8.8.8.8`. Admin router ima vanjski gateway, `enable_snat = true` i sučelje prema admin subnetu.

Jump dobiva fiksnu adresu `10.200.0.10`, Lead `10.200.0.20`, a gateway je `10.200.0.1`. Floating IP pripada Jump portu. To je jedina floating IP koju ovaj kod stvara; vanjska povezanost developer routera služi SNAT-u, a ne izravnom javnom pristupu guestima.

### 5.2 Developerske mreže i RBAC

Za developera sa slotom `<slot>` `modules/workspace` stvara subnet `10.210.<slot>.0/24`, gateway `10.210.<slot>.1`, DHCP i iste DNS poslužitelje `1.1.1.1` i `8.8.8.8`. Developer router ima gateway prema istoj vanjskoj mreži i `enable_snat = true`.

Na developerskoj mreži stvara se Neutron RBAC politika `access_as_shared` s target tenantom shared projekta. Ona omogućuje `shared-reconcile` rootu, čiji je provider ograničen na shared projekt, da stvori Jump management port na developer mreži.

### 5.3 Fiksne adrese

```text
SHARED ADMIN SUBNET: 10.200.0.0/24
  10.200.0.1     admin router gateway
  10.200.0.10    Jump
  10.200.0.20    Lead

DEVELOPER SUBNET: 10.210.<slot>.0/24
  10.210.<slot>.1   developer router gateway
  10.210.<slot>.5   Jump management NIC
  10.210.<slot>.10  app01
  10.210.<slot>.11  app02
  10.210.<slot>.20  DB
  10.210.<slot>.50  OVN load balancer VIP
```

Slika 3: Fiksni adresni plan shared i jedne developerske mreže.

| Mreža | Uloga | Fiksna adresa | Implementacija |
| --- | --- | --- | --- |
| `10.200.0.0/24` | admin gateway | `10.200.0.1` | `cidrhost(var.admin_cidr, 1)` |
| `10.200.0.0/24` | Jump | `10.200.0.10` | shared Jump port |
| `10.200.0.0/24` | Lead | `10.200.0.20` | shared Lead port |
| `10.210.<slot>.0/24` | developer gateway | `10.210.<slot>.1` | `local.gateway_ip` |
| `10.210.<slot>.0/24` | Jump management NIC | `10.210.<slot>.5` | `cidrhost(local.tenant_cidr, 5)` |
| `10.210.<slot>.0/24` | app01 | `10.210.<slot>.10` | `local.app_ips[0]` |
| `10.210.<slot>.0/24` | app02 | `10.210.<slot>.11` | `local.app_ips[1]` |
| `10.210.<slot>.0/24` | DB | `10.210.<slot>.20` | `local.db_ip` |
| `10.210.<slot>.0/24` | OVN VIP | `10.210.<slot>.50` | `cidrhost(local.tenant_cidr, 50)` |

Tablica 4: Svi fiksni IPv4 položaji koje stvara ova arhitektura.

### 5.4 Prometni tokovi

Klijentski HTTP promet stiže na VIP `10.210.<slot>.50:80` i OVN ga prosljeđuje na app01 ili app02 na port 80. DB promet s developerskog subneta ide prema `10.210.<slot>.20:3306`. SSH prema app i DB instancama dopušten je samo s Jump management adrese `.5`. Jump floating IP služi za SSH ulaz; nema floating IP-a za VIP, app, DB ili Lead.

## 6. Security grupe, SSH i zaštita gostiju

### 6.1 Neutron security grupe

Sve security grupe imaju `delete_default_rules = true`. Eksplicitna pravila su:

| Security grupa | Smjer | Protokol/port | Izvor ili odredište |
| --- | --- | --- | --- |
| `${name_seed}-jump-sg` | ingress | TCP/22 | `allowed_ssh_cidr`, zadano `0.0.0.0/0` |
| `${name_seed}-jump-sg` | egress | sav promet | nije ograničeno pravilom porta |
| `${name_seed}-lead-sg` | ingress | TCP/22 | `10.200.0.0/24` |
| `${name_seed}-lead-sg` | egress | sav promet | nije ograničeno pravilom porta |
| `${name_seed}-${slug}-app-sg` | ingress | TCP/22 | `10.210.<slot>.5/32` |
| `${name_seed}-${slug}-app-sg` | ingress | TCP/80 | `10.210.<slot>.0/24` |
| `${name_seed}-${slug}-app-sg` | egress | sav promet | nije ograničeno pravilom porta |
| `${name_seed}-${slug}-db-sg` | ingress | TCP/3306 | `10.210.<slot>.0/24` |
| `${name_seed}-${slug}-db-sg` | ingress | TCP/22 | `10.210.<slot>.5/32` |
| `${name_seed}-${slug}-db-sg` | egress | sav promet | nije ograničeno pravilom porta |

Tablica 5: Točna Neutron pravila po security grupama.

Port 9200 nije otvoren Neutron pravilima. Iako ga guest firewalld omogućuje za health servis, mrežni sloj ga ne izlaže kroz definirana security-group pravila. App HTTP pravilo izvorno je ograničeno na developerski `/24`, a ne na cijelu vanjsku mrežu.

### 6.2 SSH model i ključevi

Nova keypair naziva `${name_seed}-lead` koristi se za Jump, Lead i sve developer VM-ove. Lead javni ključ ulazi u Jump, Lead, app i DB cloud-init. Svaki developer javni ključ ulazi u Jump te u svoje app i DB instance. `scripts/ensure-ssh-keypair.sh` za developerske i Lead ključeve stvara ili provjerava RSA-3072 par; privatni developerski ključevi ostaju na operatorskom stroju.

Lead cloud-init privatni ključ kratkotrajno zapisuje u `/var/lib/techsprint/lead/`, kopira ga u `/home/<lead-slug>/.ssh/id_rsa` i zatim uklanja izvornu privremenu kopiju. Lead može koristiti taj ključ za operativni pristup developer guestima. Developer privatni ključ ne ulazi u Terraform input, state ili cloud-init.

```text
operator s developer ključem ili Lead s Lead ključem
                         |
                         | SSH na Jump floating IP
                         v
           Jump: admin 10.200.0.10 + management 10.210.<slot>.5
                         |
                         | ProxyJump na privatnu adresu
                         v
                 app01, app02 ili DB VM
```

Slika 4: SSH put od operatorskog ulaza preko Jumpa do privatnih gostiju.

Primjeri obrazaca, s namjerno generičkim vrijednostima:

```bash
ssh -i <lead-private-key> <lead-slug>@<jump-floating-ip>
ssh -o IdentitiesOnly=yes -i keys/<developer-slug>_ssh \
  -J <developer-slug>@<jump-floating-ip> \
  <developer-slug>@<private-app-or-db-ip>
```

U cloud-init predlošcima su `ssh_pwauth: false` i `disable_root: true`. Guest korisnici imaju grupu `wheel` i `sudo: "ALL=(ALL) NOPASSWD:ALL"`, ali SSH autentikacija koristi ključeve, ne lozinku.

### 6.3 Tajne i dozvole

`random_password.human` stvara OpenStack lozinku za svakog CSV korisnika, a `random_password.database` stvara lozinku Moodle baze za svakog developera. Lozinke su sensitive Terraform outputi i nalaze se u bootstrap stateu; state container i S3/Swift credentials zato moraju biti zaštićeni.

Renderirani Terraform inputi, planovi, backend HCL datoteke i state environment datoteka pišu se s dozvolom `0600`. Direktorij `keys/` je `0700`, privatni ključevi `0600`, a javni ključevi `0644`. Generirani runtime i key materijal nije predviđen za javnu verziju koda.

### 6.4 SELinux i firewalld

Jump, Lead, app i DB cloud-init predlošci postavljaju SELinux na `enforcing`, pozivaju `setenforce 1` i provjeravaju `getenforce`. App dodatno postavlja `httpd_can_network_connect_db` i `httpd_can_network_connect`, a `/var/lib/moodledata` i `/mnt/moodle-dataroot` dobivaju `httpd_sys_rw_content_t`. `/srv/mysql` dobiva `mysqld_db_t`.

| Uloga | Firewalld konfiguracija | Predložak |
| --- | --- | --- |
| Jump | servis `ssh` | `templates/jump.yaml.tftpl` |
| Lead | nema poziva konfiguracije firewallda | `templates/lead.yaml.tftpl` |
| App | servisi `http`, `ssh` i port `9200/tcp` | `templates/app.yaml.tftpl` |
| DB | servisi `mysql`, `ssh` i port `9200/tcp` | `templates/db.yaml.tftpl` |

Tablica 6: Guest firewalld konfiguracija prema ulozi.

Funkcije `configure_firewalld()` privremeno pozivaju `setenforce 0` tijekom trajnog firewalld podešavanja, reload-a i restarta servisa. `trap` i završna provjera vraćaju SELinux u `Enforcing`; to nije trajno isključivanje zaštite.

## 7. Operacijski i aplikacijski sloj

### 7.1 Rocky Linux 8.10

Sve instance bootaju iz imagea `Rocky-8-GenericCloud-Base-8.10-20240528.0.x86_64`. `scripts/upload-rocky-image.sh` podržava read-only provjeru i upload pinanog qcow2 imagea. Ugovor imagea uključuje format `qcow2`, container format `bare`, javnu vidljivost te atribute Rocky, verziju 8, arhitekturu `x86_64` i SHA-512 metadata.

### 7.2 Moodle 5.2.2, PHP 8.3, Apache i PHP-FPM

Zadana vrijednost `moodle_version` je `5.2.2`. Workspace iz verzije izvodi granu `stable502`; app cloud-init preuzima arhivu s obrasca:

```text
https://packaging.moodle.org/<moodle-branch>/moodle-<moodle-version>.tgz
```

Arhiva se prije raspakiravanja provjerava SHA-256 checksumom iz Terraform ulaza. App bootstrap instalira Apache `httpd`, PHP i PHP-FPM nakon uključivanja Remi modula `php:remi-8.3`; runtime provjera odbija PHP stariji od 8.2.0. Apache virtual host koristi `DocumentRoot /var/www/moodle/public`, a PHP zahtjeve prosljeđuje na `unix:/run/php-fpm/www.sock`.

Moodle konfiguracija koristi MariaDB driver, DB adresu `10.210.<slot>.20`, bazu naziva developer sluga i korisnika `moodle_<developer-slug>`. Apache webroot je `/var/www/moodle/public`, Moodle konfiguracijski dataroot je `/mnt/moodle-dataroot/moodledata`, lokalni cache je `/var/lib/moodledata/localcache`, a privremene datoteke su u `/var/lib/moodledata/temp`.

### 7.3 OVN load balancer

Za svakog developera stvara se `openstack_lb_loadbalancer_v2` s `loadbalancer_provider = "ovn"` i VIP adresom `10.210.<slot>.50`. Listener je TCP na portu 80. Pool je TCP, koristi metodu `SOURCE_IP_PORT`, a članovi app01 i app02 prosljeđuju promet na port 80.

OVN load balancer nema konfiguriran health monitor ni L7 usmjeravanje. Zato se članovi poola ne uklanjaju automatski na temelju health endpointa.

### 7.4 Health servisi

App guest pokreće `techsprint-app-health.service`, koji preko `python3 -m http.server` poslužuje `/var/www/health` na portu 9200. DB guest analogno pokreće `techsprint-db-health.service`. Servisi služe osnovnoj provjeri dostupnosti gosta; nisu povezani s automatskim OVN health-monitor mehanizmom.

## 8. Sloj podataka

### 8.1 MariaDB 10.11

DB VM instalira MariaDB 10.11 iz repozitorija `https://rpm.mariadb.org/10.11/rhel/8`. Konfiguracija u `/etc/my.cnf.d/techsprint.cnf` postavlja:

- `datadir=/srv/mysql`;
- Unix socket `/var/lib/mysql/mysql.sock`;
- `bind-address=0.0.0.0`;
- `character-set-server=utf8mb4`;
- `collation-server=utf8mb4_unicode_ci`.

DB bootstrap montira Cinder volumen po UUID-u na `/srv/mysql`, postavlja SELinux kontekst `mysqld_db_t`, inicijalizira bazu ako je prazna i pokreće MariaDB. Kreira bazu naziva developer sluga, korisnika `moodle_<developer-slug>` i daje mu prava na toj bazi iz host obrasca `10.210.<slot>.%`.

### 8.2 Pet Cinder volumena po developeru

Za svakog developera stvaraju se tri volumena u resursu `data` i dva u resursu `dataroot`. Svaki volumen ima 10 GiB i koristi `var.volume_type`, zadano `tripleo`.

```text
developer workspace
       |
       +-- DB VM   /dev/vdb  --> /srv/mysql
       |
       +-- app01   /dev/vdb  --> /var/lib/moodledata
       |                         +-- localcache
       |                         +-- temp
       |
       +-- app02   /dev/vdb  --> /var/lib/moodledata
       |                         +-- localcache
       |                         +-- temp
       |
       +-- app01   /dev/vdc  --> /mnt/moodle-dataroot/moodledata
       |
       +-- app02   /dev/vdc  --> /mnt/moodle-dataroot/moodledata
```

Slika 5: Raspored pet zasebnih Cinder volumena i njihovih guest mountova.

| VM | Cinder resurs i naziv | Veličina | Uređaj | Guest odredište | Namjena |
| --- | --- | ---: | --- | --- | --- |
| DB | `data["db"]`, `<prefix>-db-data` | 10 GiB | `/dev/vdb` | `/srv/mysql` | MariaDB datadir |
| app01 | `data["app01"]`, `<prefix>-app01-data` | 10 GiB | `/dev/vdb` | `/var/lib/moodledata` | localcache i temp |
| app02 | `data["app02"]`, `<prefix>-app02-data` | 10 GiB | `/dev/vdb` | `/var/lib/moodledata` | localcache i temp |
| app01 | `dataroot["app01"]`, `<prefix>-app01-dataroot` | 10 GiB | `/dev/vdc` | `/mnt/moodle-dataroot` | lokalni Moodle dataroot, poddirektorij `moodledata` |
| app02 | `dataroot["app02"]`, `<prefix>-app02-dataroot` | 10 GiB | `/dev/vdc` | `/mnt/moodle-dataroot` | lokalni Moodle dataroot, poddirektorij `moodledata` |

Tablica 7: Pet Cinder volumena po developeru, svi veličine 10 GiB.

Bootstrap predlošci čekaju da se pojave cijeli blok uređaji, odbijaju root disk `/dev/vda`, prazne diskove formatiraju kao XFS, upisuju UUID u `/etc/fstab` i provjeravaju da je stvarni mount upravo očekivani uređaj. App diskovi nisu međusobno dijeljeni.

### 8.3 Dataroot nije dijeljen

`/var/lib/moodledata` na svakoj app instanci služi samo za lokalni cache i temp. Stvarni Moodle dataroot je `/mnt/moodle-dataroot/moodledata`, ali app01 i app02 imaju odvojene `/dev/vdc` volumene. Nema shared filesystem mounta koji bi te direktorije učinio zajedničkima.

## 9. Automatizacija i tijek izvođenja

### 9.1 Operatorski ulaz `deploy.sh`

`deploy.sh` je ulazna točka i prosljeđuje operaciju odgovarajućoj skripti:

```text
./deploy.sh --init
./deploy.sh --apply [CSV]
./deploy.sh [CSV]
./deploy.sh --destroy
```

Bez navedenog CSV-a koriste se `../config/users.csv` u odnosu na `OpenStack/`. `--init` poziva `run.sh init`, `--apply` ili goli CSV pozivaju `run.sh apply`, a `--destroy` poziva `destroy.sh`.

### 9.2 `run.sh init` i `run.sh apply`

Skripta prije rada provjerava `terraform`, `openstack` i `jq`; za apply dodatno `python3` i `ssh-keygen`. Zahtijeva administratorski OpenRC s `OS_AUTH_URL`, projektom i Keystone identitetom.

Tijek apply operacije je:

1. `bootstrap-state-backend.sh` stvara ili ponovno koristi Swift container `iruo-terraform-state`, otkriva S3 endpoint, pribavlja ili ponovno koristi EC2 credentials i generira backend HCL datoteke.
2. Sva četiri roota rade `terraform init -reconfigure` s generiranim backend konfiguracijama.
3. Odabire se postojeći ili zadani `name_seed`, parsira se CSV, provjeravaju se slugovi i stvaraju zaštićeni JSON ulazi.
4. `ensure-ssh-keypair.sh` stvara ili provjerava Lead i developerske RSA-3072 parove.
5. OpenStack CLI dohvaća token identitet, domain ID i ID Rocky 8.10 imagea, osim ako je image ID izričito zadan okolišem.
6. `bootstrap` se planira i primjenjuje, zatim `roots/shared`, zatim svaki developer workspace redom, a na kraju `roots/shared-reconcile`.
7. Ispisuju se samo nesecretni izlazi poput Jump floating IP-a, shared project ID-a, LB identifikatora i generičkih SSH obrazaca.

`run.sh init` završava nakon pripreme backenda i inicijalizacije sva četiri roota; ne izvodi plan ni apply.

### 9.3 `destroy.sh`

`destroy.sh` ne prima argumente. Zahtijeva administratorski OpenRC, postojeći `runtime/terraform-state.env` i prethodno pripremljene backend/input datoteke. Inicijalizira rootove, pronađe postojeće developer workspaceove, odabere `default` za shared-reconcile, ruši rootove obrnutim redoslijedom i nakon svakog developer roota briše workspace.

Za refresh i destroy koristi se najviše 50 reconciliation pokušaja. Resurs koji je nestao iz OpenStacka može biti uklonjen iz statea samo kada dijagnostika potvrdi 404, `NotFound` ili ekvivalentnu poruku. Nakon uspjeha provjerava se da je state prazan. Globalni backend, EC2 credentials i Rocky image ostaju netaknuti.

### 9.4 Pomoćne skripte

| Skripta | Funkcija |
| --- | --- |
| `scripts/bootstrap-state-backend.sh` | Swift container, S3 endpoint, EC2 credentials, state environment i četiri backend HCL datoteke |
| `scripts/render-terraform-inputs.py` | CSV parsing, aliasi zaglavlja, transliteracija slugova i JSON input contract |
| `scripts/ensure-ssh-keypair.sh` | RSA-3072 generiranje i provjera podudarnosti javnog i privatnog ključa |
| `scripts/upload-rocky-image.sh` | read-only provjera ili provjereni upload pinanog Rocky imagea |

Tablica 8: Pomoćne skripte deploymenta i njihove odgovornosti.

### 9.5 CSV i runtime ugovor

CSV mora sadržavati ime, prezime i ulogu; podržana su zaglavlja `ime;prezime;rola` ili kanonski ekvivalenti. Uloga se normalizira u `developer` ili `devops_lead`. Točno jedan zapis mora biti `devops_lead`, a najmanje dva zapisa moraju biti `developer`. Slug se izvodi iz imena i prezimena, mora biti jedinstven i ne smije biti `default`.

Renderer čuva redoslijed developer slugova radi sekvencijalnog applya. `runtime/terraform-inputs/` i `runtime/plans/` sadrže generirane, zaštićene materijale; nisu ulazni source arhitekture.

## 10. Ograničenja i poznata odstupanja

### 10.1 Nedijeljeni Moodle dataroot

Najvažnije odstupanje od tipične HA Moodle topologije jest da `/mnt/moodle-dataroot/moodledata` nije dijeljen. Svaki app ima vlastiti `/dev/vdc`; load balancer može isti korisnički promet usmjeravati na instance s različitim datotekama.

### 10.2 Ograničenja load balancera i health provjere

OVN LB radi TCP/80 distribuciju i nema health monitor ni L7 routing. Port 9200 je lokalni health servis u guestu, ali nije povezan s automatskim uklanjanjem člana poola. Ne postoji floating IP za developer VIP.

### 10.3 Ovisnost o platformi

Deployment ovisi o regiji `regionOne`, dostupnoj vanjskoj mreži, Rocky 8.10 imageu, Cinder tipu `tripleo`, OpenStack provideru `3.4.0` te MariaDB i Remi repozitorijima.

### 10.4 Mrežni i operativni kapacitet

Network slotovi imaju raspon 0–63, pa se u jednom `name_seed` deploymentu može koristiti najviše 64 jedinstvena slota, uz dodatni uvjet da hashirani slugovi nemaju koliziju. Zadano `allowed_ssh_cidr = 0.0.0.0/0` otvara SSH do Jumpa prema cijelom IPv4 prostoru; za stvarni rad treba koristiti uži operatorski CIDR.

### 10.5 Privremeno SELinux odstupanje

Guest bootstrap privremeno koristi `setenforce 0` tijekom firewalld konfiguracije. `trap` vraća enforcing način rada, a završna provjera zahtijeva `getenforce == Enforcing`. To je ograničeno inicijalizacijsko odstupanje, ne trajno isključenje SELinuxa.

## 11. Zaključak

Opisana Terraform arhitektura daje ponovljivu osnovu za izolirane IRUO Moodle testne okoline na OpenStacku. Shared projekt centralizira ulaz i administraciju, developer projekti odvajaju identitete i mreže, a rootovi i remote state ugovori određuju kontrolirani redoslijed životnog ciklusa. Rocky 8.10, Moodle 5.2.2, PHP 8.3, Apache/PHP-FPM i MariaDB 10.11 čine standardizirani gostujući runtime.

Moodle dataroot je lokalni na svakoj aplikacijskoj instanci, OVN LB nema health monitor, a floating IP postoji samo na Jumpu. Cinder osigurava DB disk te odvojene lokalne diskove za cache, temp i Moodle podatke po aplikacijskoj instanci.
