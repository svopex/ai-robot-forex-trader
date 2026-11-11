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

### Testovaci tlacitko

Nad log dej testovaci tlacitko, ktere zada obchody pri stisknuti. Aby se dalo testovat...

