# Azure TechSprint — scenarij snimke deploymenta i provjere

**Ciljano trajanje:** približno 15–20 minuta, uz dodatno stvarno vrijeme čekanja
na Terraform i Ansible korake. Čekanje se može ubrzati prikazom terminala s
neutralnom porukom o napretku, ali se rezultat ne smije unaprijed proglasiti
uspješnim.

Ovaj je tekst praktičan predložak za snimanje. Sve vrijednosti označene
šiljastim zagradama treba popuniti samo lokalno tijekom snimanja; u predanoj
snimci i dokumentaciji ne prikazuju se stvarna javna IP adresa, privatni
ključevi, lozinke, Terraform state, vault ili generirani inventar.

Kriteriji se temelje na [autoritativnom projektnom briefu](../../docs/IRUO_Projekt_2025_2026-2.pdf),
stranicama 2–5, i na Azure pravilima iz [`AGENTS.md`](../../AGENTS.md).

## Kontrolni popis prije snimanja

- [ ] Potvrđeno je da je aktivna prava Azure pretplata i Entra tenant; prijava
      je već obavljena izvan snimke ili se prikazuje samo bezosjetljivi rezultat.
- [ ] Lokalni deployment ulaz `config/users.csv` je UTF-8 datoteka sa zaglavljem
      `ime;prezime;rola` i točno jednim `devops_lead` te najmanje dva
      `developer` retka.
- [ ] U snimci se prikazuje i čita samo sanitizirani `config/users.example.csv`;
      stvarni `config/users.csv` može biti ulaz naredbe, ali se ne ispisuje.
- [ ] Instalirani su PowerShell 7.4+, Terraform, Ansible i potrebni Az moduli.
- [ ] Marketplace uvjeti za Rocky Linux 10, potrebne registracije i kvote
      riješeni su unaprijed, bez automatskog mijenjanja pretplate tijekom
      snimanja.
- [ ] Postoji sigurna, lokalno ignorirana lokacija za ključeve, state, planove,
      vault i inventar. Njihov sadržaj nije dio snimke.
- [ ] Za završnu provjeru dostupni su samo zamjenski markeri za Jump IP,
      privatne adrese, naziv gatewaya i privatni ključ.
- [ ] Prije završne tvrdnje planirano je ponovno pokretanje Ansiblea i dokaz
      idempotencije; ono se ne prikazuje kao završeno dok stvarno ne vrati
      očekivani rezultat.

### Sigurna higijena zaslona

Prije snimanja zatvoriti prozore s `clouds.yaml`, OpenRC varijablama,
lozinkama, tokenima, SAS vrijednostima, connection stringovima, privatnim
ključevima, planovima, stateom i punim inventarom. U terminalu koristiti
zamjenske vrijednosti poput `<JUMP_PUBLIC_IP>` i `<PRIVATE_KEY>`, a ne stvarne
vrijednosti. Ne prikazivati prompt za lozinku ni izlaz koji ga može sadržavati.
Ako se otvori Azure Portal, prikazati samo relevantni status resursa i
zamaskirati subscription ID, javnu IP adresu i osobne podatke.

## CSV i kriteriji zadatka

Snimka pokazuje da jedan ulazni CSV opisuje traženi testni opseg. Sanitizirani
primjer `config/users.example.csv` je:

```text
ime;prezime;rola
ana;anic;devops_lead
luka;lukic;developer
iva;ivic;developer
```

Validator zahtijeva točno jedan `devops_lead`, najmanje dva `developer` retka,
valjano UTF-8 semikolon-zaglavlje, jedinstvene lowercase slugove i
kolizijski slobodne determinističke mrežne slotove. Svaki developer dobiva
izoliran okoliš s dvije Moodle aplikacijske instance. Aplikacije, baza,
pohrana, load balancer i Lead nemaju izravan javni pristup; jedina javno
dostupna ulazna točka je Jump.

## Scenarij po scenama

| Vrijeme | Što prikazati | Near-verbatim hrvatska naracija i sigurne naredbe |
| --- | --- | --- |
| 0:00–0:45 | Naslov, repozitorij i cilj snimke | „Ovo je Azure implementacija TechSprint Moodle testnog okruženja. Pokazat ću ulazni CSV, jednu lokalnu naredbu za Azure providera, arhitekturu, sigurnosni model, procjenu troška i provjeru privatnog Moodle prometa. Čekanje na deployment nije uključeno u ciljano trajanje. Neću prikazivati tajne, state, inventar ni stvarnu javnu IP adresu.” |
| 0:45–1:45 | Kontrolni popis i siguran terminal | „Prije promjene provjeravam aktivni Azure kontekst i alate. Ovo je samo provjera lokalnih preduvjeta; ne registriram providere, ne povećavam kvote i ne izvršavam cloud pozive za potrebe ovog dokumentacijskog zadatka. Na ekranu ostaju samo sažeci bez identifikatora.” Sigurne lokalne provjere: `pwsh --version`, `terraform version`, `ansible --version`. |
| 1:45–3:00 | CSV u editoru | „Ulaz je točno jedan UTF-8 CSV sa zaglavljem `ime;prezime;rola`. Ovdje su Ana kao DevOps Lead te Luka i Iva kao developeri. Validator odbija pogrešno zaglavlje, nepoznatu ulogu, duplikate i mrežne kolizije; time se osigurava upravo jedan Lead i najmanje dva developera.” Prikazati samo sanitizirani CSV: `python3 -c "from pathlib import Path; print(Path('../config/users.example.csv').read_text(encoding='utf-8'))"`. |
| 3:00–4:30 | Provider-local entry point i sažetak | „Cijeli podržani put pokreće se jednom naredbom iz Azure direktorija. Naredba prihvaća CSV i sama provodi validaciju, read-only razrješenje konteksta i deployment profila, planiranje, odobreni apply, generiranje inventara, konfiguraciju i provjeru zdravlja.” Iz Bash ljuske, samo nakon odobrenja deploymenta i pregleda plana: `cd Azure && pwsh -File ./deploy.ps1 -UsersCsv ../config/users.csv`. Stvarni CSV nije dio prikaza. |
| 4:30–6:00 | Faze one-shot orkestracije, bez tajni | „Najprije se validiraju korisnici i deterministička imena. Zatim se iz aktivne sesije read-only određuju subscription, tenant, UPN domena, region, suffix, Rocky image i VM SKU. Slijedi preflight i state backend. Nedostajući Entra korisnici stvaraju se uz maskirani unos lozinke, bez zapisivanja lozinke u plan ili state. Terraform zatim planira i primjenjuje shared foundation, svaki developer tenant i završnu shared reconciliation fazu. Tek nakon toga nastaju sanitizirani staging fragmenti, zaštićeni vault i lokalni Ansible inventar te se pokreće konfiguracija i provjera zdravlja. Na snimci pokazujem samo statusne retke.” |
 | 6:00–7:30 | [Azure arhitektura: pregled hub-a i spokeova — SVG](architecture/azure-architecture-video-hr.svg) / [PNG fallback](architecture/azure-architecture-video-hr.png) | „Najprije gledamo pregled. State, shared i developer resource groupovi čine sestrinske resource grupe u testing pretplati. Shared hub sadrži Jump, privatni Lead, privatni Application Gateway i DNS. Radna stanica ide isključivo kroz jedinu javnu IP adresu Jumpa: tunel zatim doseže privatni gateway ili privatni Lead. Dva developerska spokea su izolirana; nema cross-spoke prometa. Privatni app VM-ovi izlaze prema Internetu samo kroz SNAT na Jumpu.” |
| 7:30–9:00 | [Azure arhitektura: detalj jednog developer okruženja — SVG](architecture/azure-developer-environment-video-hr.svg) / [PNG fallback](architecture/azure-developer-environment-video-hr.png) | „Sada zumiram jedan spoke. Host ruta privatnog Application Gatewaya vodi prema `app01` u zoni 1 i `app02` u zoni 2. Oba su Rocky Linux 10 VM-a od točno 2 vCPU i 4 GiB RAM-a, s OS diskom od 32 GiB i odvojenim data diskom od 32 GiB. MySQL 8.4 je jedan zajednički General Purpose ZoneRedundant server u hubu, primarna zona 1 i standby zona 2; ovaj developer koristi samo vlastiti `moodle_<slug>` database/user/grant. Files NFSv4.1 s `AUTH_SYS` služi za zajednički dataroot i primarne backupove, a Blob kroz UAMI i BlobFuse2 za replikaciju. `/readyz` vrijedi tek kada TLS `SELECT 1` i sva tri točna mounta budu potvrđena.” |
| 9:00–10:15 | VM-ovi i privatno usmjeravanje | „Promet aplikacije ide prema privatnom host-routed Standard_v2 Application Gatewayu na `10.10.2.10:8080`; privatne aplikacije nisu javno izložene. Privatni izlaz prema Internetu za instalaciju paketa ide kroz SNAT na Jumpu. Lead može administrirati aplikacije kroz hub-spoke privatnu vezu, dok developer ne dobiva pristup tuđem spokeu.” |
| 10:15–11:45 | Moodle, MySQL i pohrana | „Moodle koristi jedan zajednički MySQL Flexible Server 8.4, `GP_Standard_D2ds_v4`, GeneralPurpose i ZoneRedundant, s primarnom zonom 1 i standby zonom 2. Svaki developer ima odvojeni `moodle_<slug>` database, user i grant. Server je u hub subnetu `10.10.3.0/24`; zato je trošak jedan fiksni HA server, ali kvar ili problem mrežne dostupnosti ima zajednički blast radius. DNS link prema spokeovima pojavljuje se nakon shared reconcile. Za zajednički `moodledata` i primarno odredište automatiziranih sigurnosnih kopija koristi se Azure Files Premium FileStorage LRS, NFSv4.1, montiran na obje aplikacijske instance. Blob je zasebna objektna pohrana: UAMI s najmanjim potrebnim pravima koristi BlobFuse2, a timer kopira Moodle-generated datoteke sigurnosnih kopija u Blob kao repliku. Važno ograničenje: NFS koristi `AUTH_SYS`/`sec=sys` i ovaj odabrani native NFS transport nema enkripciju u prijenosu.” |
| 11:45–12:45 | Entra, RBAC, imena i resolver | „Entra grupe i korisnici prate uloge iz CSV-a. Developer dobiva Reader i uski `TechSprint VM Power Operator` samo nad vlastitim aplikacijskim VM-ovima. DevOps Lead dobiva upravljanje projektnim VM-ovima. UAMI svakog developera dobiva Blob Data Contributor samo na vlastitom Blob računu; nema Azure Files data-plane ulogu. Sva sredstva koja podržavaju tagove nose `project=techsprint` i `environment=testing`, uz owner i scope. Imena su deterministička i uključuju scope, testing i regionalni suffix. Read-only resolver prvo pokušava `westeurope`, zatim `swedencentral`, a SKU bira prema dostupnosti, zonama, obliku 2 vCPU/4 GiB i stvarnoj regionalnoj i family kvoti: `Standard_B2s`, zatim `Standard_B2als_v2`, pa `Standard_D2als_v6`. Nikad se ne bira `Standard_B2ats_v2` jer ima samo 1 GiB RAM.” |
| 12:45–13:45 | Procjena troška | „Za sljedeći deployment ove provjerene pretplate fiksna procjena iznosi približno **795,43 USD mjesečno** u regiji Sweden Central, sa `Standard_D2als_v6`, **uz varijabilne naknade za korištenje**. To je procjena za 24/7 rad, 730 sati mjesečno, Pay-As-You-Go javne USD cijene bez popusta, rezervacija ili Hybrid Benefita, za dva developera i jednog Leada. Uključuje šest VM-ova s istim odabranim SKU-om, privatni Application Gateway s pretpostavljenim prosjekom jedne kapacitetne jedinice, diskove, MySQL, Premium Files, Blob, jednu javnu IP adresu, četiri privatna endpointa i pet privatnih DNS zona. Nisu izmišljene količine prometa ili DNS upita; Private Link obrada ulaznog i izlaznog prometa, DNS upiti i bandwidth obračunavaju se prema stvarnom korištenju. Jeftinije povijesne procjene nisu usporedive jer su component-only iznosi bez privatnih endpointa i DNS zona; `Standard_D2als_v6` izbor je uvjetovan kvotom.” |
| 13:45–16:15 | Lokalni Linux SSH tunel i HTTP provjera | „Sada privatni gateway provjeravam s lokalne Linux radne stanice. Developerski SSH tunel ide kroz jedini Jump public IP, ali odredište tunela je privatni `10.10.2.10:8080`, a lokalni port je `8080`. Developersko Jump korisničko ime točno je slug developera, a koristi se odgovarajući privatni ključ `Azure/keys/<slug>`. Alternativa za Leada ili operatora je korisnik `azureuser` i Leadov ključ. U naredbi su samo placeholderi.” Otvoriti tunel: `ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes -o ExitOnForwardFailure=yes -N -L 127.0.0.1:8080:10.10.2.10:8080 <slug>@<JUMP_PUBLIC_IP>`. U drugom terminalu, za svaki slug: `curl -i --resolve '<slug>.moodle.test:8080:127.0.0.1' http://<slug>.moodle.test:8080/readyz`, zatim `curl -sS -L --resolve '<slug>.moodle.test:8080:127.0.0.1' -o /dev/null -w 'final_http_status=%{http_code}\n' http://<slug>.moodle.test:8080/` — konačni status mora biti 200 — pa više puta `curl -i --resolve '<slug>.moodle.test:8080:127.0.0.1' http://<slug>.moodle.test:8080/whoami`. |
| 16:15–18:00 | Backend health, mountovi, HA i Nginx popravak | „`/readyz` je provjera spremnosti: Ansible najprije root-level `findmnt --mountpoint` provjerava sva tri točna mounta, zatim na montiranim datotečnim sustavima zapisuje deployment-bound markere, a `/readyz` provjerava te markere i izvršava TLS MySQL `SELECT 1`. Lokalni XFS data-disk tree trajno je označen s `httpd_sys_rw_content_t` samo za enforcing `httpd_t` PHP-FPM pristup; NFS/Blob labeli se ne proširuju. Raniji live HTTP 200 koristio je staru, slabiju readiness krajnju točku, pa je samo djelomičan dokaz. `/whoami` mora identificirati backend; ponavljam ga više puta i bilježim da odgovori dolaze s `app01` i `app02` ili da je svaki backend potvrđen. Backend health Application Gatewaya mora pokazati zdrave pool članove.” Sigurna Azure provjera nakon prijave: `Get-AzApplicationGatewayBackendHealth -ResourceGroupName "<SHARED_RG>" -Name "<APP_GATEWAY_NAME>"`. Mount provjera kroz Jump: `ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes -o ProxyJump="<slug>@<JUMP_PUBLIC_IP>" "<APP_SSH_USER>@<APP01_PRIVATE_IP>" -- 'findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-shared; findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-objects; findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /srv/moodle-local'`, a zatim ista naredba za `<APP02_PRIVATE_IP>`. „U dosadašnjem live dokazu stara `/readyz` provjera za jednog tenanta vratila je 200, ali `/` je vratio Nginx 403. Izvorni template sada sadrži `index index.php;`. Ansible se mora ponovno primijeniti, a zatim treba zabilježiti i nove točne provjere mountova i root HTTP 200; to još nije potvrđeno i ne smije se prikazati kao završni uspjeh.” |
| 18:00–19:30 | Drugi Ansible run i dokaz idempotencije | „Nakon popravka pokrećem Ansible još jednom s istim sigurnim ulazima. Završni dokaz je drugi run s nula neočekivanih promjena, bez grešaka, uz očuvane mountove, usluge i health endpoint. Snimam samo sažetak `PLAY RECAP` i broj promjena, nikad inventar ili vault.” U stvarnom workspaceu koristi se generirani production inventar i lokalno zaštićeni vault prema runbooku; ne upisivati ih u naredbu ni dokumentaciju. Nakon toga ponavljam `/readyz`, `/` i `/whoami`. |
| 19:30–20:00 | Zaključak i rubric checklist | „Zaključujem samo ono što je dokazano. Za ovu snimku moram imati: točan CSV, dvije app instance po developeru, privatni gateway s host routingom, jedini Jump javni ulaz, privatni Lead, MySQL i oba storage mounta, zdrav backend, `/readyz` 200, root 200 nakon Nginx popravka, HA dokaz kroz `/whoami`, drugi idempotentni Ansible run te odvojene RBAC/power-action provjere. Ako bilo koji dokaz nedostaje, status ostaje djelomičan i to izričito navodim.” |

Oba dijagrama dostupna su kao [native-text SVG pregledni dijagram](architecture/azure-architecture-video-hr.svg)
i [native-text SVG detalj](architecture/azure-developer-environment-video-hr.svg),
uz [PNG pregledni fallback](architecture/azure-architecture-video-hr.png) i
[PNG detaljni fallback](architecture/azure-developer-environment-video-hr.png).
SVG je prikladan za zumiranje i uređivanje, a PNG preporučujem kada recorder ili
preglednik ne prikazuje SVG tekstualne elemente.

## Post-deployment checklist za snimku (Linux Bash)

Ove naredbe su praktični cueovi, s placeholderima umjesto runtime vrijednosti.
Dva poziva `ansible-playbook` mijenjaju živu konfiguraciju: nakon provjere
ciljnog konteksta i odobrenja pokrećem Ansible jednom, a zatim još jednom za
idempotenciju.
`ansible.cfg` sam bira generirani inventory i vault; u snimci se prikazuje samo
`PLAY RECAP`, nikad njihov sadržaj.

```bash
(
  set -euo pipefail
  cd Azure/ansible
  KEY="../keys/<LEAD_SLUG>"
  test -f "$KEY"
  chmod 600 "$KEY"
  test -r "$KEY"

  eval "$(ssh-agent -s)"
  trap 'ssh-agent -k >/dev/null 2>&1' EXIT
  ssh-add "$KEY" >/dev/null

  # Opcionalno: provjera puta do privatnog Leada.
  ansible lead -m ping --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  # Prvi konfiguracijski run; bilježim samo PLAY RECAP.
  ansible-playbook playbooks/deploy_moodle.yml \
    --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  # Drugi identični run za provjeru idempotencije.
  ansible-playbook playbooks/deploy_moodle.yml \
    --private-key "$KEY" \
    --ssh-common-args '-o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null'

  ssh-agent -k >/dev/null 2>&1
  trap - EXIT
)
```

„Ovo je reapply stvarne konfiguracije, a drugi identični poziv je dokaz
idempotencije. Normalni put i dalje je `cd Azure && pwsh -File ./deploy.ps1
-UsersCsv ../config/users.csv`; on automatski upravlja agentom. Ovaj namjerni
Bash rerun koristi zaseban agent, a `ansible.cfg` automatski bira generirani
inventory i vault. Ne snimam vault, inventory, state, plan ni privatni ključ.
Ako se pojavi `Connection closed by UNKNOWN port 65535`, to ovdje znači da je
autentikacija u ugniježđenom ProxyCommand/Jump `ssh ... -W` procesu neuspjela;
ne znači TCP port 65535 niti brisanje Lead VM-a. Status ostaje djelomičan dok
se stvarni run i njegov `PLAY RECAP` ne zabilježe.”

Tunel s lokalnog Linux računala koristi developerski slug i
`Azure/keys/<slug>`. Lead/operator alternativa je `azureuser` s ključem
`Azure/keys/<LEAD_SLUG>`; u oba slučaja odredište ostaje privatni AGW.

```bash
JUMP_IP='<JUMP_PUBLIC_IP>'
ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes -N \
  -L 127.0.0.1:8080:10.10.2.10:8080 "<slug>@${JUMP_IP}"

# alternativa za Leada/operatora
ssh -i "Azure/keys/<LEAD_SLUG>" -o IdentitiesOnly=yes \
  -o ExitOnForwardFailure=yes -N \
  -L 127.0.0.1:8080:10.10.2.10:8080 "azureuser@${JUMP_IP}"
```

S drugim terminalom pripremam provjeru. `/readyz` mora vratiti 200, a canonical
`/` prati redirecte i mora završiti s 200 bez prikaza tijela. `/whoami` ponavljam
više puta; ne očekujem određen round-robin redoslijed, nego zasebno potvrđujem
`app01` i `app02`.

```bash
set -euo pipefail
HOST='<slug>.moodle.test'
ready_body="$(mktemp)"; trap 'rm -f "$ready_body"' EXIT
ready_status="$(curl -sS --resolve "${HOST}:8080:127.0.0.1" \
  -o "$ready_body" -w '%{http_code}' "http://${HOST}:8080/readyz")"
printf 'readyz_body=%s status=%s\n' "$(tr '\n' ' ' < "$ready_body")" "$ready_status"
test "$ready_status" = 200
root_status="$(curl -sS -L -o /dev/null -w '%{http_code}' \
  --resolve "${HOST}:8080:127.0.0.1" "http://${HOST}:8080/")"
printf 'root_final_status=%s\n' "$root_status"; test "$root_status" = 200

seen_app01=0; seen_app02=0
for sample in 1 2 3 4 5 6; do
  result="$(curl -fsS --resolve "${HOST}:8080:127.0.0.1" \
    "http://${HOST}:8080/whoami")"
  case "$result" in *app01*) seen_app01=1;; *app02*) seen_app02=1;; esac
done
printf 'observed_app01=%s observed_app02=%s\n' "$seen_app01" "$seen_app02"
test "$seen_app01" = 1; test "$seen_app02" = 1
```

„Sada provjeravam backend health i mountove, bez ispisa punog gateway objekta
ili inventara.”

```bash
az network application-gateway show-backend-health \
  --resource-group '<SHARED_RG>' --name '<APP_GATEWAY_NAME>' \
  --query 'backendAddressPools[].backendHttpSettingsCollection[].servers[].{address:address,health:health,probeLog:healthProbeLog}' \
  -o table

for app_ip in '<APP01_PRIVATE_IP>' '<APP02_PRIVATE_IP>'; do
  ssh -i "Azure/keys/<slug>" -o IdentitiesOnly=yes \
    -o ProxyJump="<slug>@<JUMP_PUBLIC_IP>" "<APP_SSH_USER>@${app_ip}" -- \
    'findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /srv/moodle-local;
     findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-shared;
     findmnt -rn -o TARGET,FSTYPE,OPTIONS --target /mnt/moodle-objects'
done
```

Očekujem data disk na `/srv/moodle-local`, Files NFSv4.1 s `sec=sys` na
`/mnt/moodle-shared` i BlobFuse2 na `/mnt/moodle-objects`; FUSE tip ne
hardkodiram jer može ovisiti o verziji. S privatnog Leada zatim pokrećem
`ssh "app-<slug>-app01" -- 'hostname'` i `ssh "app-<slug>-app02" -- 'hostname'`.
Kod greške prikazujem samo `systemctl --failed`, status Nginxa/php-fpm-a i
`journalctl -u nginx -u php-fpm --since '-15 min' --no-pager`.

`/readyz` 200 nakon novog izvora potvrđuje deployment-bound markere za sva tri
mounta i TLS MySQL `SELECT 1`; root 200 potvrđuje Nginx/Moodle put. 403 znači odbijen zahtjev,
502 neispravan odgovor backenda, a 503 nespreman backend ili gateway. Start,
restart i deallocate su mutirajući RBAC testovi: rade se samo uz izričito
odobren cilj i obavezno vraćanje početnog stanja.

### Promjene izvornog ponašanja koje treba potvrditi uživo

Leadova Ansible uloga sada na privatnom Lead VM-u generira vlastiti operativni
privatni ključ; prema aplikacijama se uz `no_log` propagira samo javni dio.
Lead dobiva generirane SSH alias-e i provjeru SSH putanja. To je trenutno
offline-provjereno ponašanje izvora, a ne live dokaz: mora se ponovno primijeniti
Ansible i zabilježiti uspješna provjera prije tvrdnje da je funkcionalnost
aktivna.

Mjerodavne Linux Bash naredbe za reapply, drugi idempotentni run, tunel,
readiness, root, `/whoami`, backend health, mountove i Lead SSH nalaze se u
[kontrolnom popisu za post-deployment provjeru](#post-deployment-checklist-za-snimku-linux-bash)
iznad. Nula neočekivanih promjena u drugom runu dokaz je tek kada je stvarno
opažena; do tada se nove source promjene ne smatraju live primijenjenima.

## Tumačenje HTTP rezultata

- **200** — očekivani uspjeh. Za novu `/readyz` provjeru znači da su u
  Ansible je prethodno s `findmnt --mountpoint` potvrdio sva tri točna mounta i
  zapisao deployment-bound markere na njih, a `/readyz` je potvrdio te markere i
  uspješan TLS MySQL `SELECT 1`; za `/` znači da je početna Moodle stranica poslužena;
  za `/whoami` znači da je backend identitet vraćen.
- **403** — aplikacija ili Nginx je dosegnut, ali zahtjev je odbijen. U ovoj
  snimci početni `/` je ranije dao Nginx 403 zbog nedostajuće
  `index index.php;` direktive. Nakon ponovne primjene Ansiblea mora se
  promatrati i potvrditi **200**, prije nego se snimka proglasi uspješnom.
- **502** — gateway nije dobio valjan odgovor od backend aplikacije; provjeriti
  privatni listener, host routing, NSG i stanje app VM-ova.
- **503** — backend nije spreman ili nema zdravih članova. Za `/readyz` prvo
  provjeriti MySQL i oba mounta; za gateway provjeriti backend health i
  dostupnost privatnog porta.

## Završni rubric checklist i poštena ograničenja

- [ ] Točno jedan `devops_lead` i najmanje dva `developer` retka iz jednog
      semicolon CSV-a.
- [ ] Svaki developer ima dvije Moodle VM instance, `app01` u zoni 1 i
      `app02` u zoni 2, Rocky Linux 10, 2 vCPU/4 GiB te OS i data disk.
- [ ] Jedini javni ulaz je Jump; Lead, aplikacije, MySQL, Files, Blob i
      Application Gateway ostaju privatni.
- [ ] Privatni gateway na `10.10.2.10:8080` host-routa promet prema oba
      app backenda; developerovi spokeovi međusobno su izolirani.
- [ ] Files Premium NFSv4.1 je zajednički `moodledata` i primarni backup,
      BlobFuse2/UAMI je stvarno korištena backup replika, a oba su montirana
      na oba app VM-a.
- [ ] Entra/RBAC, tagovi, determinističko imenovanje te quota-aware
      region/SKU izbor su prikazani.
- [ ] `/readyz` je 200, `/` je 200 **tek nakon** Ansible primjene Nginx fix-a,
      `/whoami` potvrđuje oba backenda, mountovi i App Gateway backend health
      su zdravi.
- [ ] Drugi Ansible run je stvarno izvršen i idempotentan; svježi developer i
      Lead power-action testovi imaju zaseban dokaz.

Offline Azure provjere prije snimanja uključuju Terraform root validation,
`terraform fmt`, Ansible syntax i inventory provjere. Live dokaz od 2026-09-04 zasad
je parcijalan: developerov tunel kroz jedini Jump javni IP dosegao je privatni
Application Gateway, a ranija, slabija `/readyz` krajnja točka za jednog tenanta
vratila je HTTP 200. Tada je `/` vraćao Nginx 403. Izvorni popravci su offline
provjereni, ali ponovna Ansible primjena, točne provjere mountova iz
  deployment-bound markeri, SELinux relabeling i nova provjera spremnosti, root HTTP 200, puni deployment,
drugi idempotentni run i svježi RBAC/power testovi još nisu potvrđeni. NFS `AUTH_SYS` bez enkripcije transporta,
zajednički MySQL HA server, zajednički failure/blast-radius i trošak koji ovisi o pretplati ostaju dokumentirana
ograničenja, a ne razlozi za prešućivanje nedostajućih dokaza.
