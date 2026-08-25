# Hvordan iLO Monitor fungerer

Denne filen forklarer i detalj hva `ilo-monitor.sh` gjør, steg for steg, basert på koden slik den er i dag.

## Oppstart

1. Scriptet finner sin egen mappe og laster `config.env` derfra. Finnes ikke filen, avbrytes kjøringen med en feilmelding.
2. Det oppretter statuskatalogen `/var/lib/ilo-monitor` (brukes til cooldown-filer og SEL-markører) hvis den ikke finnes.
3. Alt som logges skrives til `/var/log/ilo-monitor.log` med tidsstempel og nivå (INFO/WARN/ERROR).

## Kommandolinjekommandoer

Kjøres scriptet med et argument, gjøres kun den ene tingen og scriptet avslutter:

| Kommando | Hva den gjør |
|---|---|
| *(ingen)* | Full sjekk: temperatur (SDR) + hendelseslogg (SEL) |
| `test` | Sender en test-melding til ntfy |
| `sel` | Viser de siste 40 linjene av rå SEL-logg fra iLO |
| `sdr` | Viser rå sensordata (SDR) fra iLO |
| `status` | Viser statusfiler, SEL-markører og de siste 30 loggradene |
| `reset-alerts` | Nullstiller cooldown-tilstand (varsler kan trigges igjen umiddelbart) |
| `reset-sel` | Nullstiller SEL-markører (alle historiske hendelser varsles på nytt) |
| `help` | Viser bruksanvisning |

## Full sjekk (standard kjøring, hvert 5. minutt via cron)

`check_ilo` kjøres for `ILO_G9_*`-serveren fra `config.env`:

1. **Tilgjengelighetssjekk** – prøver `ipmitool chassis status` mot iLO.
   - Svarer den ikke: venter 60 sekunder og prøver på nytt.
   - Svarer den fortsatt ikke: sender et varsel om at iLO ikke svarer (med cooldown, så du ikke spammes).
   - Svarer den på andre forsøk: logges det som en forbigående hang, ingen alarm sendes.
   - Svarer den med en gang: eventuell tidligere "IPMI nede"-cooldown nullstilles.
2. **Temperatursjekk (`check_sdr_g9`)** – henter sensordata (`sdr`) og går gjennom hver linje:
   - Ser kun på sensorer som starter med tall (01-29) eller navn som `Inlet`, `CPU`, `Ambient`.
   - Ignorerer støylinjer med `DutyCycle` eller `Presence`.
   - Er status `critical` eller `non-recoverable`, sendes et TEMP-varsel til ntfy (med cooldown per sensor).
3. **SEL-sjekk (`check_sel`)** – henter hendelsesloggen (`sel elist`) og går gjennom hver linje:
   - Sammenligner hendelses-ID (hex) mot forrige lagrede ID, slik at kun *nye* hendelser vurderes.
   - Filtrerer bort støy: `System ACPI Power State`, `Drive Present Deasserted`, `Pre-Init`, `Drive Inserted`.
   - Resten sjekkes mot nøkkelord: `Fault`, `Fail`, `Assert`, `Error`, `Critical`, `Degraded`, `Array`, `Power Unit`.
   - Treff samles opp og sendes som ett SEL-varsel til ntfy. Siste sett ID lagres, slik at samme hendelse ikke varsles på nytt.

## Cooldown-mekanismen

For å unngå at samme feil varsler hvert 5. minutt, lagres et tidsstempel per varseltype i `${STATE_DIR}/<nøkkel>.last` (f.eks. `g9_temp_cpu_1.last`, `dl380_g9_ipmi_down.last`). Et nytt varsel av samme type sendes først når `ALERT_COOLDOWN` sekunder (standard 3600 = 1 time) har gått siden forrige.

SEL-hendelser bruker en egen mekanisme (`_sel_last_id`) uavhengig av cooldown — de varsles kun én gang per unike hendelses-ID, uansett tid.

## Konfigurasjon (`config.env`)

- `ILO_G9_IP` / `ILO_G9_USER` / `ILO_G9_PASS` / `ILO_G9_NAME` – tilkoblingsdetaljer og visningsnavn for serveren.
- `NTFY_URL` – full URL (inkludert topic) til ntfy-instansen varsler sendes til.
- `ALERT_COOLDOWN` – minste antall sekunder mellom gjentatte varsler for samme feil.

## Installasjon (`install.sh`)

Kjøres som root på en fersk Debian-LXC:

1. Installerer `ipmitool` og `curl`.
2. Oppretter `/opt/ilo-monitor` og `/var/lib/ilo-monitor`, samt loggfilen `/var/log/ilo-monitor.log`.
3. Kopierer scriptet og konfigurasjonen dit, med begrensede tilgangsrettigheter (`config.env` er kun lesbar for eier).
4. Setter opp en cron-jobb (`/etc/cron.d/ilo-monitor`) som kjører full sjekk hvert 5. minutt.

**Merk:** `install.sh` kopierer fra `ilo_monitor.sh` (understrek), mens filen i repoet heter `ilo-monitor.sh` (bindestrek) — filnavnene må stemme overens for at installasjonen skal fungere.
