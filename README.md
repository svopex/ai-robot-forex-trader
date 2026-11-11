# AiRobotForexTrader — vstup do pozice na základě vstupního souboru

## Zadani 

### Vstupni soubor

Adresar: Z:\RRRRMMDD.yaml

Struktura souboru:

```yaml
GBPUSD Short+:
  symbol: GBPUSD
  entry_price: 1.3296
  target_price: 1.32612
USDCHF Long+:
  symbol: USDCHF
  entry_price: 0.82685
  target_price: 0.82922
AUDJPY Long+:
  symbol: AUDJPY
  entry_price: 109.541
  target_price: 109.88
AUDJPY Short+:
  symbol: AUDJPY
  entry_price: 108.239
  target_price: 107.9
NZDJPY Long+:
  symbol: NZDJPY
  entry_price: 89.227
  target_price: 89.489
```

MT5 umí běžně číst soubory jen ze svého sandboxu (MQL5\Files nebo Common\Files), ne přímo ze Z:\.
Pouzij WinAPI kernel32.
Expert čte Z:\ přímo přes systémový kernel32.dll; v MT5 je nutné povolit „Povolit import DLL“.

### Jak obchodovat

V nastaveni pouzivas exchange_timezone: America/New_York
Ve stanoveny cas (bude v nastaveni) v time: 08:00 se nactou data ze souboru a vytvori se cekajici stop pokyny.
pending_cancel_time: "11:00" - cas zruseni cekajicich pokynu
pending_cancel_time_friday: "9:00" - cas zruseni cekajicich pokynu v patek
Pokud obchod nelze zadat vzhledem k aktualni cene, obchod nezadavas.

### Zavreni obchodu

Podle seance symbolu.
10 minut před koncem obchodní seance symbolu u brokera (SymbolInfoSessionTrade).

### Velikost PT a SL

Dve moznosti:

* 15 pointu (1.5 pipu) + spread. Znovu do nastaveni.
* Podle yaml + spread, RRR 1:1, PT i SL se od vstupu oddálí o aktuální spread.

Defaultne prvni moznost.

### OCO vazba

V YAML může být pro stejný symbol Long i Short (např. AUDJPY). Co s druhým pokynem, když se první otevře?
Zrušit druhý (OCO) - když se otevře jeden pokyn na symbolu, protilehlý čekající pokyn téhož symbolu se smaže.

### Riziko 

Riziko v % z účtu, defaultne 1%.

### Dodatecne pokyny

Programujes pro MT5.
Expert musi prezit svuj restart nebo orevreni a zavreni platformy.
Loguje vse co se deje na obrazovku pod `obchodovani jednim kliknutim` na obrazovce (existuje nejaky prikaz na log na ibrazovku MT5).
Pokud nekdo smaze cekajici pokyny, jiz je znovu ten den nezadavas. Zadavas je pouze jednou ve stanoveny cas.
Platforma (expert) se spustí až po čase zadání (např. v 9:30 NY, zadání bylo v 8:00) a dnes se ještě nic nezadalo. Co dělat? Den vynechat.
Má stisk testovacího tlačítka ovlivnit automatické denní zadání v 08:00? Ne, jen zadá obchody.
Jeden graf obchoduje vše.

### Mapovani symbolu

Symboly v souboru yaml mohou mit odlisny format nez ma MT5, je treba symboly nejak "chytre" pripadne upravit, namapovat na MT5.
Aktualne pocitej s tvarem symbolu v yaml podle ukazky vyse.

### Testovaci tlacitko

Nad log dej testovaci tlacitko, ktere zada obchody pri stisknuti. Aby se dalo testovat...

## Implementace

Expert `MQL5/Experts/AiRobotForexTrader/AiRobotForexTrader.mq5` stačí vložit na
**jeden libovolný graf** – obchoduje všechny symboly ze souboru. Hlavní smyčka běží
v časovači jednou za sekundu (nečeká na ticky symbolu grafu).

### Denní zadání

- Časy (`time`, `pending_cancel_time`, `pending_cancel_time_friday`) jsou v pásmu
  burzy `exchange_timezone`. Čas burzy se počítá z GMT času počítače včetně letního
  času; podporovaná pásma: `America/New_York`, `America/Chicago`, `Europe/London`,
  `Europe/Prague`, `Europe/Berlin`, `UTC`.
- Ve čas zadání expert načte `<adresář>\RRRRMMDD.yaml` (datum v pásmu burzy) přes
  `kernel32.dll` a zadá čekající pokyny: záznam s `Long` v názvu = **BUY STOP**,
  se `Short` = **SELL STOP** na `entry_price`. Znak `+` v názvu se ignoruje; když
  název neobsahuje Long ani Short, směr se určí podle polohy `target_price` vůči
  `entry_price`.
- Zadává se **jen přesně v čase**: expert musí běžet už před časem zadání (zadání se
  musí stihnout do 60 s). Když se spustí později, den se vynechá a zaloguje.
- Zadání proběhne nejvýš **jednou za den** – den se označí jako vyřízený hned (i při
  chybě souboru). Stav přežije restart (globální proměnná terminálu
  `ARFT_<magic>_day`), smazané pokyny se týž den znovu nezadají. O víkendu se nezadává.
- Pokyn, který nelze vzhledem k aktuální ceně zadat (BUY STOP pod Ask, SELL STOP nad
  Bid nebo blíž než minimální vzdálenost brokera), se přeskočí a zaloguje.

### PT, SL a objem

- **Pevně** (výchozí): PT i SL jsou od vstupu ve vzdálenosti
  `body (15) × point + aktuální spread`.
- **Podle YAML**: vzdálenost `|target_price − entry_price| + aktuální spread`, PT i SL
  stejně daleko (RRR 1:1).
- Objem se dopočítá tak, aby ztráta na SL byla `riziko %` (výchozí 1 %) zůstatku účtu,
  zaokrouhlí se dolů na krok objemu. Když nestačí ani minimální lot, pokyn se nezadá.

### Zrušení, OCO a zavření

- V čas zrušení (v pátek `pending_cancel_time_friday`) expert smaže nevyplněné
  čekající pokyny zadané před tímto časem. Pokyn má navíc na serveru nastavenou
  platnost do času zrušení (pokud ji symbol podporuje) – zruší se i při vypnutém
  terminálu.
- **OCO**: když se otevře pozice z pokynu experta, protilehlý čekající pokyn téhož
  symbolu se smaže (hned v `OnTradeTransaction`, záložně kontrolou každou sekundu).
- Pozice i zbylé pokyny experta se zavřou **10 minut před koncem obchodní seance
  symbolu** u brokera (`SymbolInfoSessionTrade`, seance, ve které obchod vznikl).
  Když terminál v tu dobu neběží, zavře je při nejbližší otevřené seanci. Zavírání
  pozic na konci seance vyžaduje běžící terminál.
- Pokyny a pozice experta se poznají podle magic number, takže správa přežije restart
  experta i terminálu.

### Testovací tlačítko

Tlačítko **ZADAT OBCHODY ZE SOUBORU (TEST)** nad logem okamžitě načte dnešní soubor
a zadá z něj pokyny (bez potvrzení). Denní automatické zadání neovlivní. Pokyny
zadané po čase zrušení zůstanou až do zavření před koncem seance symbolu.

### Mapování symbolů

Symbol ze souboru se hledá v tomto pořadí: ruční mapování ze vstupu
(`GBPUSD=GBPUSD.r;AUDJPY=AUDJPY.r`) → přesný název → chytré hledání mezi všemi
symboly serveru (bez ohledu na velikost písmen a znaky jako `/` `.` `#`, s
předponou/příponou brokera; u měnového páru musí sedět základní i kotovaná měna,
přednost má nejkratší přídavek a symbol v Market Watch). Nalezený symbol se přidá do
Market Watch a mapování se zaloguje.

### Zobrazení v grafu

Log se vypisuje příkazem `Comment()` vlevo nahoře – MT5 ho sám posune pod okno
*One Click Trading*. První řádek je stav (verze, čas burzy, stav dnešního zadání, čas
zrušení, počet čekajících pokynů a pozic experta), pod ním log – nejnovější zpráva
nahoře, chyby s prefixem `CHYBA:`, upozornění s `POZOR:`. Nad textem jsou prázdné
řádky, ve kterých leží testovací tlačítko. Vše se zapisuje i do Expert logu s
prefixem `ARFT:`.

## Nastavení

| Parametr | Výchozí | Popis |
|---|---|---|
| Adresář se souborem | `Z:\` | kde leží `RRRRMMDD.yaml` |
| Časové pásmo burzy | `America/New_York` | `exchange_timezone` |
| Čas zadání | `08:00` | `time` |
| Čas zrušení | `11:00` | `pending_cancel_time` |
| Čas zrušení v pátek | `09:00` | `pending_cancel_time_friday` |
| Zavřít X minut před koncem seance | `10` | |
| Velikost PT a SL | Pevně | Pevně: body + spread / Podle YAML + spread (RRR 1:1) |
| Pevná vzdálenost PT a SL | `15` | body (15 = 1,5 pipu), přičte se spread |
| Riziko na obchod | `1.0` | % zůstatku účtu |
| Magic number | `202611110800` | odlišuje pokyny a pozice experta |
| Ruční mapování symbolů | prázdné | `YAML=MT5` oddělené `;` |
| Počet řádků logu | `15` | |
| Prázdné řádky nad logem | `2` | místo pro testovací tlačítko |
| Tlačítko – odsazení X / Y, posun pod One Click | `12` / `20` / `60` | px při 96 DPI |

## Spuštění

1. Nasazení a kompilace do všech nainstalovaných MT5: `scripts\deploy.cmd -All`
   (jen jeden terminál: `scripts\deploy.cmd -Broker "IC Markets"`).
2. V MT5 přetáhnout experta (Navigator → Experts → AiRobotForexTrader) na libovolný
   graf a ve vlastnostech zapnout **Povolit import DLL** a **Povolit Algo Trading**.
3. Terminál musí mít přístup na disk se vstupním souborem (např. připojený `Z:\`).

### Omezení

- Čas burzy se odvozuje z hodin počítače – musí jít správně.
- Ve Strategy Testeru vrací `TimeGMT()` čas serveru, čas burzy tam proto nesedí.

## Struktura projektu

```
MQL5/Experts/AiRobotForexTrader/AiRobotForexTrader.mq5   expert (UTF-8 s BOM)
scripts/deploy.cmd, scripts/deploy.ps1                    nasazení a kompilace do MT5
```

## Verzování

Verze experta je v `EA_VERSION` (`#property version`) na začátku
`AiRobotForexTrader.mq5` a zobrazuje se v logu při spuštění. Před každým nasazením
nové verze se zvýší:

| Změna | Zvýšení | Příklad |
|---|---|---|
| oprava chyby | +0.01 | 1.00 → 1.01 |
| nová funkce | +0.10 | 1.00 → 1.10 |
| zásadní změna | +1.00 | 1.00 → 2.00 |

Commit s novou verzí se označí tagem `vX.YY`.

**Aktuální verze: 1.01**

