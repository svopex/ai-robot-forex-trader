//+------------------------------------------------------------------+
//|                                           AiRobotForexTrader.mq5 |
//|                                                                  |
//|  Denní vstup do pozic podle vstupního souboru RRRRMMDD.yaml:     |
//|   - ve stanovený čas (časové pásmo burzy) načte soubor mimo      |
//|     sandbox MT5 přes kernel32.dll a zadá čekající BUY STOP /     |
//|     SELL STOP pokyny,                                            |
//|   - PT a SL: pevně body + spread, nebo podle YAML (zadané % ze   |
//|     vzdálenosti vstup-cíl) + spread (RRR 1:1),                   |
//|   - objem se dopočítá z rizika (% zůstatku účtu),                |
//|   - OCO: po otevření pozice smaže protilehlý pokyn téhož symbolu,|
//|   - v čas zrušení smaže nevyplněné pokyny (v pátek dřív),        |
//|   - pozice zavře X minut před koncem obchodní seance symbolu,    |
//|   - vše loguje do grafu pod okno One Click Trading; nad logem je |
//|     testovací tlačítko, které zadá obchody hned,                 |
//|   - sekce Options v souboru: trading: disabled = nezadává nic.   |
//|  Jeden graf obchoduje všechny symboly ze souboru.                |
//+------------------------------------------------------------------+
// Verze experta - zvyšuje se před každým nasazením (viz README, Verzování)
#define EA_VERSION "1.23"

#property copyright "AiRobotForexTrader"
#property version   EA_VERSION
#property description "Denní čekající stop pokyny podle souboru RRRRMMDD.yaml (čtení přes kernel32.dll), objem z rizika, OCO, zrušení pokynů v daný čas a zavření pozic před koncem seance symbolu."

#include <Trade\Trade.mqh>

//--- Čtení souboru mimo sandbox MT5 přes WinAPI. Vyžaduje v MT5
//--- povolené „Povolit import DLL“, jinak volání expert zastaví.
#import "kernel32.dll"
long CreateFileW(string fileName, uint desiredAccess, uint shareMode, long securityAttributes,
                 uint creationDisposition, uint flagsAndAttributes, long templateFile);
int  GetFileSizeEx(long file, long &fileSize);
int  ReadFile(long file, uchar &buffer[], uint bytesToRead, uint &bytesRead, long overlapped);
int  CloseHandle(long handle);
uint GetLastError(void);
#import

//--- Konstanty WinAPI pro CreateFileW a kódy chyb GetLastError
#define ARFT_GENERIC_READ          0x80000000
#define ARFT_FILE_SHARE_READ_WRITE 0x00000003
#define ARFT_OPEN_EXISTING         3
#define ARFT_FILE_ATTRIBUTE_NORMAL 0x00000080
#define ARFT_INVALID_HANDLE        -1
#define ARFT_ERROR_FILE_NOT_FOUND  2
#define ARFT_ERROR_PATH_NOT_FOUND  3
#define ARFT_ERROR_ACCESS_DENIED   5

//--- Způsob výpočtu vzdálenosti PT a SL od vstupu
enum ENUM_ARFT_STOPS
  {
   ARFT_STOPS_FIXED = 0, // Pevně: body + spread
   ARFT_STOPS_YAML  = 1  // Podle YAML (% z cíle) + spread (RRR 1:1)
  };

//--- Vstupní soubor
input group "=== Vstupní soubor ==="
input string InpInputDir                 = "Z:\\";            // Adresář se souborem RRRRMMDD.yaml

//--- Časy v časovém pásmu burzy
input group "=== Čas (pásmo burzy) ==="
input string InpExchangeTimezone         = "America/New_York"; // Časové pásmo burzy (exchange_timezone)
input string InpPlaceTime                = "08:00";           // Čas zadání čekajících pokynů (time)
input string InpPendingCancelTime        = "11:00";           // Čas zrušení čekajících pokynů (pending_cancel_time)
input string InpPendingCancelTimeFriday  = "09:00";           // Čas zrušení v pátek (pending_cancel_time_friday)
input int    InpCloseBeforeSessionEndMin = 10;                // Zavřít pozice X minut před koncem seance symbolu

//--- Obchod
input group "=== Obchod ==="
input ENUM_ARFT_STOPS InpStopsMode       = ARFT_STOPS_FIXED;  // Velikost PT a SL
input int    InpFixedStopsPoints         = 15;                // Pevná vzdálenost PT a SL (body, + spread)
input double InpYamlStopsPercent         = 100.0;             // Podle YAML: % ze vzdálenosti vstup-cíl (100 = celý cíl)
input double InpRiskPercent              = 1.0;               // Riziko na obchod (% zůstatku)
input long   InpMagic                    = 202611110800;      // Magic number

//--- Mapování symbolů z YAML na symboly brokera
input group "=== Mapování symbolů ==="
input string InpSymbolMap                = "";                // Ruční mapování YAML=MT5 (oddělené ;), např. GBPUSD=GBPUSD.r

//--- Zobrazení v grafu
input group "=== Graf ==="
input int    InpLogLines                 = 15;                // Počet řádků logu v grafu
input int    InpButtonLines              = 3;                 // Prázdné řádky nad logem (místo pro testovací tlačítko)
input int    InpButtonX                  = 12;                // Testovací tlačítko - odsazení X (px při 96 DPI)
input int    InpButtonY                  = 20;                // Testovací tlačítko - odsazení Y (px při 96 DPI)
input int    InpOneClickShift            = 60;                // Posun tlačítka pod okno One Click Trading (px při 96 DPI)

//--- Pojmenované konstanty místo magických čísel v kódu
#define ARFT_LOG_TAG          "ARFT: "    // prefix řádků v Expert logu
#define ARFT_COMMENT          "ARFT "     // prefix komentáře denních pokynů
#define ARFT_COMMENT_TEST     "ARFT test " // prefix komentáře pokynů z testovacího tlačítka
#define ARFT_COMMENT_MAX      31          // nejdelší komentář pokynu, který server přijme
#define ARFT_DAY_SECONDS      86400       // sekund ve dni
#define ARFT_PLACE_GRACE_SEC  60          // nejpozději tolik s po čase zadání smí zadání proběhnout
#define ARFT_SWEEP_PAUSE_SEC  30          // pauza úklidu po neúspěšném smazání / zavření
#define ARFT_MIN_EXPIRY_SEC   60          // nejkratší platnost pokynu, se kterou ji ještě posílat serveru
#define ARFT_MAX_FILE_SIZE    1048576     // horní mez velikosti vstupního souboru (B)
#define ARFT_DATA_WAIT_MS     3000        // nejdelší čekání na ceny a hodnotu ticku nově přidaných symbolů (ms)
#define ARFT_DATA_POLL_MS     50          // pauza mezi pokusy o data symbolu (ms)
#define ARFT_LOTSTEP_EPS      1e-7        // tolerance plovoucí čárky při zaokrouhlení lotu
#define ARFT_MAX_RISK_PCT     100.0       // horní mez rizika na obchod (%)
#define ARFT_MAX_YAML_PCT     1000.0      // horní mez % ze vzdálenosti vstup-cíl v režimu podle YAML
#define ARFT_MAX_LOG_LINES    50          // horní mez počtu řádků logu v grafu
#define ARFT_MAX_BUTTON_LINES 10          // horní mez prázdných řádků nad logem
#define ARFT_PLACE_ERROR      -1          // PlaceOrdersFromFile: chyba souboru / obchodování
#define ARFT_PLACE_DISABLED   -2          // PlaceOrdersFromFile: soubor má Options trading: disabled

// Testovací tlačítko - rozměry v pixelech při 96 DPI. Souřadnice objektů
// jsou ve fyzických pixelech, písmo se ale s DPI zvětšuje samo - rozměry
// se proto za běhu násobí měřítkem (viz Dpi).
#define ARFT_BUTTON           "ARFT_test" // název objektu tlačítka (jediný objekt experta v grafu)
#define ARFT_BASE_DPI         96.0        // DPI, pro které jsou rozměry níže
#define ARFT_BTN_W            220         // šířka testovacího tlačítka
#define ARFT_BTN_H            20          // výška testovacího tlačítka
#define ARFT_BTN_FONT_SIZE    8           // velikost písma tlačítka

//--- Jeden obchod ze vstupního souboru
struct STradeSetup
  {
   string            key;     // název záznamu v YAML (např. "GBPUSD Short+")
   string            symbol;  // symbol z YAML (před mapováním na MT5)
   double            entry;   // entry_price - cena stop pokynu
   double            target;  // target_price - cíl pro režim PT/SL podle YAML
  };

//--- Volby ze sekce Options vstupního souboru (sekce je nepovinná)
struct SFileOptions
  {
   bool              trading; // trading: enabled = obchoduje se; bez volby také
  };

//--- Pravidla letního času podporovaných časových pásem
enum ENUM_ARFT_DST
  {
   ARFT_DST_NONE, // bez letního času
   ARFT_DST_US,   // USA: 2. neděle března - 1. neděle listopadu, 2:00 místního času
   ARFT_DST_EU    // EU: poslední neděle března - poslední neděle října, 1:00 UTC
  };

//--- Globální stav experta
CTrade        g_trade;
int           g_tzStdOffset     = 0;             // standardní posun pásma burzy od UTC (s)
ENUM_ARFT_DST g_tzDst           = ARFT_DST_NONE; // pravidlo letního času pásma burzy
int           g_placeSec        = 0;             // čas zadání (s od půlnoci, pásmo burzy)
int           g_cancelSec       = 0;             // čas zrušení pokynů (s od půlnoci)
int           g_cancelFridaySec = 0;             // čas zrušení pokynů v pátek (s od půlnoci)
datetime      g_initExchange    = 0;             // čas spuštění experta (pásmo burzy)
int           g_doneDay         = 0;             // den RRRRMMDD, kdy bylo denní zadání vyřízeno
string        g_dayState        = "";            // výsledek dnešního zadání pro stavový řádek
datetime      g_sweepPauseUntil = 0;             // do kdy (čas serveru) je úklid po chybě pozastaven
string        g_symbolFrom[];                    // mapování symbolů: normalizovaný symbol z YAML
string        g_symbolTo[];                      // mapování symbolů: symbol MT5 (ruční ze vstupu + nalezené)
string        g_logText[];                       // řádky logu v grafu, nejnovější na indexu 0
double        g_dpiScale        = 1.0;           // měřítko DPI monitoru (1.0 = 96 DPI)
bool          g_oneClickShown   = false;         // bylo při umístění tlačítka vidět One Click Trading?
string        g_commentText     = "";            // naposledy vypsaný text Comment()

//+------------------------------------------------------------------+
//| Inicializace: kontrola vstupů, obnova denního stavu, tlačítko.   |
//+------------------------------------------------------------------+
int OnInit()
  {
   //--- Nesmyslné vstupy se odmítnou hned při startu, ne až v čase zadání
   g_placeSec        = ParseTimeOfDay(InpPlaceTime);
   g_cancelSec       = ParseTimeOfDay(InpPendingCancelTime);
   g_cancelFridaySec = ParseTimeOfDay(InpPendingCancelTimeFriday);
   if(g_placeSec < 0 || g_cancelSec < 0 || g_cancelFridaySec < 0)
     {
      Print(ARFT_LOG_TAG, "neplatný čas zadání nebo zrušení - očekává se HH:MM.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(!InitTimezone(InpExchangeTimezone))
     {
      Print(ARFT_LOG_TAG, "nepodporované časové pásmo '", InpExchangeTimezone,
            "' - podporováno: America/New_York, America/Chicago, Europe/London, Europe/Prague, Europe/Berlin, UTC.");
      return(INIT_PARAMETERS_INCORRECT);
     }
   if(InpRiskPercent <= 0.0 || InpRiskPercent > ARFT_MAX_RISK_PCT || InpFixedStopsPoints <= 0 ||
      InpYamlStopsPercent <= 0.0 || InpYamlStopsPercent > ARFT_MAX_YAML_PCT ||
      InpCloseBeforeSessionEndMin < 0 || InpLogLines < 1 || InpLogLines > ARFT_MAX_LOG_LINES ||
      InpButtonLines < 0 || InpButtonLines > ARFT_MAX_BUTTON_LINES)
     {
      PrintFormat("%sneplatné vstupy - riziko 0..%.0f %%, body PT/SL > 0, %% z YAML 0..%.0f, "
                  "minuty před koncem seance >= 0, řádky logu 1..%d, prázdné řádky nad logem 0..%d.",
                  ARFT_LOG_TAG, ARFT_MAX_RISK_PCT, ARFT_MAX_YAML_PCT, ARFT_MAX_LOG_LINES, ARFT_MAX_BUTTON_LINES);
      return(INIT_PARAMETERS_INCORRECT);
     }
   string badPair;
   if(!ParseSymbolMap(InpSymbolMap, badPair))
     {
      Print(ARFT_LOG_TAG, "neplatné mapování symbolů '", badPair, "' - očekává se YAML=MT5;YAML=MT5.");
      return(INIT_PARAMETERS_INCORRECT);
     }

   g_trade.SetExpertMagicNumber(InpMagic);
   g_trade.SetAsyncMode(false);
   g_trade.LogLevel(LOG_LEVEL_ERRORS);

   g_dpiScale = MathMax(0.5, TerminalInfoInteger(TERMINAL_SCREEN_DPI) / ARFT_BASE_DPI);

   //--- Při změně symbolu / periody grafu se expert neukončí a globální
   //--- proměnné zůstanou - log i čas spuštění se zachovají. Jinak se
   //--- začíná znovu: čas spuštění rozhoduje, zda expert stihne dnešní zadání.
   if(UninitializeReason() != REASON_CHARTCHANGE)
     {
      g_initExchange = ExchangeNow();
      ArrayResize(g_logText, InpLogLines);
      for(int i = 0; i < InpLogLines; i++)
         g_logText[i] = "";
     }

   //--- Den, kdy už bylo zadání vyřízeno, přežije restart v globální
   //--- proměnné terminálu - smazané pokyny se týž den znovu nezadají
   if(GlobalVariableCheck(DoneVarName()))
      g_doneDay = (int)GlobalVariableGet(DoneVarName());

   //--- OnDeinit komentář smazal - po inicializaci se vypíše znovu
   g_commentText = "";
   CreateTestButton();
   if(!EventSetTimer(1))
     {
      Print(ARFT_LOG_TAG, "nelze spustit časovač.");
      return(INIT_FAILED);
     }

   LogInfo(StringFormat("AiRobotForexTrader v%s, build %s, magic %I64d.",
                        EA_VERSION, TimeToString(__DATETIME__), InpMagic));
   LogInfo(StringFormat("Pásmo %s: zadání %s, zrušení %s (pátek %s), zavření %d min před koncem seance.",
                        InpExchangeTimezone, InpPlaceTime, InpPendingCancelTime,
                        InpPendingCancelTimeFriday, InpCloseBeforeSessionEndMin));
   LogInfo(StringFormat("PT/SL: %s, riziko %.2f %% zůstatku, soubor %s.",
                        InpStopsMode == ARFT_STOPS_FIXED ? StringFormat("%d b + spread", InpFixedStopsPoints)
                                                         : StringFormat("%g %% z YAML + spread", InpYamlStopsPercent),
                        InpRiskPercent, InputFilePath(ExchangeNow())));

   if(!MQLInfoInteger(MQL_DLLS_ALLOWED))
      LogError("Import DLL není povolen - soubor nepůjde načíst. Zapněte „Povolit import DLL“ ve vlastnostech experta.");

   //--- Stav se vyhodnotí hned, ne až za sekundu
   OnTimer();
   return(INIT_SUCCEEDED);
  }

//+------------------------------------------------------------------+
//| Ukončení: časovač, tlačítko a log v grafu.                       |
//+------------------------------------------------------------------+
void OnDeinit(const int reason)
  {
   EventKillTimer();
   ObjectDelete(0, ARFT_BUTTON);
   Comment("");
   ChartRedraw();
  }

//+------------------------------------------------------------------+
//| Hlavní smyčka - jednou za sekundu. Obchoduje se více symbolů,    |
//| proto se nečeká na ticky symbolu grafu.                          |
//+------------------------------------------------------------------+
void OnTimer()
  {
   const datetime now = ExchangeNow();
   CheckDailyPlacement(now);

   //--- Úklid se po neúspěšném požadavku na chvíli pozastaví, aby se
   //--- neopakoval každou sekundu a nezahltil log
   if(TimeTradeServer() >= g_sweepPauseUntil)
     {
      EnforceOco();
      ExpirePendings();
      CloseBeforeSessionEnd();
     }

   //--- Pojistka k CHARTEVENT_CHART_CHANGE pro přepnutí One Click Trading
   RelayoutIfNeeded();
   ShowComment();
  }

//+------------------------------------------------------------------+
//| Klik na testovací tlačítko a změna grafu.                        |
//+------------------------------------------------------------------+
void OnChartEvent(const int id, const long &lparam, const double &dparam, const string &sparam)
  {
   //--- Testovací tlačítko zadá obchody hned; denní zadání neovlivní
   if(id == CHARTEVENT_OBJECT_CLICK && sparam == ARFT_BUTTON)
     {
      ObjectSetInteger(0, sparam, OBJPROP_STATE, false);
      PlaceOrdersFromFile(ExchangeNow(), true);
      ShowComment();
      ChartRedraw();
     }
   //--- Tlačítko je ukotvené k rohu grafu; posun a zoom grafu ho neovlivní,
   //--- přesouvá se jen při zapnutí / vypnutí One Click Trading
   else if(id == CHARTEVENT_CHART_CHANGE)
      RelayoutIfNeeded();
  }

//+------------------------------------------------------------------+
//| Obchodní události: OCO po otevření pozice a log všeho, co se     |
//| stalo s pokyny a pozicemi experta (i zásahy uživatele).          |
//+------------------------------------------------------------------+
void OnTradeTransaction(const MqlTradeTransaction &trans,
                        const MqlTradeRequest &request,
                        const MqlTradeResult &result)
  {
   //--- Log a stav se obnoví hned jen u transakcí, které mohou něco zalogovat;
   //--- ostatní (a počty pokynů) obnoví časovač do sekundy
   if(trans.type == TRADE_TRANSACTION_DEAL_ADD)
      OnDealAdded(trans.deal);
   else if(trans.type == TRADE_TRANSACTION_HISTORY_ADD)
      OnOrderArchived(trans.order);
   else
      return;
   ShowComment();
  }

//====================================================================
// Denní zadání
//====================================================================

//+------------------------------------------------------------------+
//| Zadá denní pokyny, když nastal čas zadání.                       |
//|  now - aktuální čas v pásmu burzy                                |
//| Zadává se jen přesně v čase: expert musí běžet už před ním.      |
//| Když se spustí později (nebo byl PC uspaný), den se vynechá.     |
//+------------------------------------------------------------------+
void CheckDailyPlacement(const datetime now)
  {
   const int today = DayKey(now);
   if(g_doneDay == today)
      return;
   const datetime placeAt = DayStart(now) + g_placeSec;
   if(now < placeAt)
      return;

   //--- Den se označí jako vyřízený hned - pokyny se zadávají nejvýš
   //--- jednou za den, i když zadání selže nebo je někdo později smaže
   MarkDayDone(today);

   //--- Expert nastartoval až po čase zadání, nebo se čas zadání
   //--- propásl (uspání PC, zaseknutý terminál) - den se vynechá
   if(g_initExchange >= placeAt || now > placeAt + ARFT_PLACE_GRACE_SEC)
     {
      g_dayState = "vynecháno";
      LogWarn(StringFormat("Den %d vynechán: expert neběžel v čase zadání %s.", today, InpPlaceTime));
      return;
     }

   //--- O víkendu se nic nezadává (trh je zavřený, soubor nebývá)
   MqlDateTime dt;
   TimeToStruct(now, dt);
   if(dt.day_of_week == SATURDAY || dt.day_of_week == SUNDAY)
     {
      g_dayState = "víkend";
      LogInfo("Víkend - nic se nezadává.");
      return;
     }

   //--- Výsledek zadání pro stavový řádek
   const int placed = PlaceOrdersFromFile(now, false);
   g_dayState = placed == ARFT_PLACE_DISABLED ? "neobchoduje se (Options)"
                : placed < 0 ? "chyba" : StringFormat("zadáno %d", placed);
  }

//--- Uloží den vyřízeného zadání (přežije restart terminálu)
void MarkDayDone(const int day)
  {
   g_doneDay = day;
   GlobalVariableSet(DoneVarName(), day);
   GlobalVariablesFlush();
  }

//--- Název globální proměnné terminálu se dnem posledního zadání
string DoneVarName()
  {
   return(StringFormat("ARFT_%I64d_day", InpMagic));
  }

//+------------------------------------------------------------------+
//| Načte dnešní soubor a zadá z něj čekající stop pokyny.           |
//|  now    - aktuální čas v pásmu burzy (určuje název souboru)      |
//|  isTest - true = testovací tlačítko (jen jiný komentář pokynu)   |
//| Vrací počet zadaných pokynů, ARFT_PLACE_ERROR při chybě souboru  |
//| / obchodování, ARFT_PLACE_DISABLED při Options trading: disabled.|
//+------------------------------------------------------------------+
int PlaceOrdersFromFile(const datetime now, const bool isTest)
  {
   const string path = InputFilePath(now);
   LogInfo(StringFormat("%s: načítám %s", isTest ? "Test" : "Denní zadání", path));

   string reason;
   string text;
   if(!ReadTextFile(path, text, reason))
     {
      LogError(StringFormat("Soubor %s nelze načíst: %s.", path, reason));
      return(ARFT_PLACE_ERROR);
     }

   STradeSetup  setups[];
   SFileOptions options;
   ParseYaml(text, setups, options);

   //--- Soubor sám vypíná obchodování ve svátek, bank holiday a o víkendu
   //--- (Options: trading: disabled) - nezadá se nic, ani testovacím tlačítkem.
   //--- Záznamy se pak ani neověřují, aby log nezahlcovala varování.
   if(!options.trading)
     {
      LogInfo("Soubor vypíná obchodování (Options trading) - dnes se nic nezadává.");
      return(ARFT_PLACE_DISABLED);
     }
   const int count = ValidateSetups(setups);
   if(count == 0)
     {
      LogWarn("Soubor neobsahuje žádný platný obchod.");
      return(0);
     }

   //--- Povolení obchodování se kontroluje až po souboru, aby v den bez
   //--- obchodování nehlásil chybu vypnutý Algo Trading
   if(!TradingAllowed(reason))
     {
      LogError("Obchodování není povoleno: " + reason + ".");
      return(ARFT_PLACE_ERROR);
     }

   //--- Všechny symboly se přidají do Market Watch hned: terminál pak stahuje
   //--- jejich ceny i kurzy pro přepočet hodnoty ticku (např. USDJPY pro
   //--- NZDJPY) souběžně se zadáváním prvních pokynů. Nenalezený symbol
   //--- zaloguje až PlaceSetup. Na data všech symbolů se čeká společně
   //--- nejvýš ARFT_DATA_WAIT_MS od jejich přidání, ne zvlášť u každého.
   string symbol;
   for(int i = 0; i < count; i++)
      ResolveSymbol(setups[i].symbol, symbol);
   const ulong dataDeadline = GetTickCount64() + ARFT_DATA_WAIT_MS;

   int placed = 0;
   for(int i = 0; i < count; i++)
      if(PlaceSetup(setups[i], isTest, dataDeadline))
         placed++;

   const string summary = StringFormat("Zadáno %d z %d pokynů.", placed, count);
   if(placed == count)
      LogInfo(summary);
   else
      LogWarn(summary);
   return(placed);
  }

//+------------------------------------------------------------------+
//| Zadá jeden čekající stop pokyn podle záznamu ze souboru.         |
//|  setup        - obchod ze souboru                                |
//|  isTest       - pokyn z testovacího tlačítka                     |
//|  dataDeadline - do kdy (GetTickCount64) čekat na data symbolu    |
//| Pokyn, který vzhledem k aktuální ceně nelze zadat, se přeskočí.  |
//+------------------------------------------------------------------+
bool PlaceSetup(const STradeSetup &setup, const bool isTest, const ulong dataDeadline)
  {
   string symbol;
   if(!ResolveSymbol(setup.symbol, symbol))
     {
      LogError(StringFormat("%s: symbol %s v MT5 nenalezen.", setup.key, setup.symbol));
      return(false);
     }

   const int direction = SetupDirection(setup);
   if(direction == 0)
     {
      LogError(StringFormat("%s: nelze určit směr (Long/Short).", setup.key));
      return(false);
     }
   const bool isBuy = direction > 0;
   const string typeName = isBuy ? "BUY STOP" : "SELL STOP";

   string reason;
   if(!SymbolTradable(symbol, isBuy, reason))
     {
      LogWarn(StringFormat("%s: nezadáno - %s.", setup.key, reason));
      return(false);
     }

   MqlTick tick;
   if(!WaitForSymbolData(symbol, dataDeadline, tick))
     {
      LogError(StringFormat("%s: chybí aktuální cena %s.", setup.key, symbol));
      return(false);
     }

   const int    digits = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double point  = SymbolInfoDouble(symbol, SYMBOL_POINT);
   const double spread = tick.ask - tick.bid;
   const double entry  = NormalizePrice(symbol, setup.entry);

   //--- Vzdálenost PT i SL od vstupu (RRR 1:1), oddálená o aktuální spread:
   //--- pevný počet bodů, nebo zadané procento ze vzdálenosti vstup-cíl ze
   //--- souboru (např. 30 % = PT i SL ve 30 % cesty k target_price)
   double distance = InpFixedStopsPoints * point + spread;
   if(InpStopsMode == ARFT_STOPS_YAML)
     {
      const double yamlDistance = isBuy ? setup.target - setup.entry : setup.entry - setup.target;
      if(yamlDistance <= 0.0)
        {
         LogError(StringFormat("%s: target_price %s neleží ve směru obchodu.",
                               setup.key, DoubleToString(setup.target, digits)));
         return(false);
        }
      distance = yamlDistance * InpYamlStopsPercent / 100.0 + spread;
     }

   //--- Stop pokyn musí ležet za trhem (BUY STOP nad Ask, SELL STOP pod
   //--- Bid) aspoň o minimální vzdálenost brokera; jinak se nezadává
   const double stopsLevel = (double)SymbolInfoInteger(symbol, SYMBOL_TRADE_STOPS_LEVEL) * point;
   const double minGap     = MathMax(stopsLevel, point);
   const double gap        = isBuy ? entry - tick.ask : tick.bid - entry;
   if(gap < minGap)
     {
      LogWarn(StringFormat("%s: nezadáno - %s %s je %s trhu (%s %s).", setup.key, typeName,
                           DoubleToString(entry, digits), gap < 0.0 ? "za" : "příliš blízko",
                           isBuy ? "Ask" : "Bid", DoubleToString(isBuy ? tick.ask : tick.bid, digits)));
      return(false);
     }
   if(distance < stopsLevel)
     {
      LogWarn(StringFormat("%s: nezadáno - PT/SL %s je blíž než minimální vzdálenost brokera.",
                           setup.key, DoubleToString(distance, digits)));
      return(false);
     }

   const double sl = NormalizePrice(symbol, isBuy ? entry - distance : entry + distance);
   const double tp = NormalizePrice(symbol, isBuy ? entry + distance : entry - distance);

   const double lots = CalcLot(symbol, MathAbs(entry - sl), reason);
   if(lots <= 0.0)
     {
      LogWarn(StringFormat("%s: nezadáno - %s.", setup.key, reason));
      return(false);
     }

   ENUM_ORDER_TYPE_TIME typeTime;
   datetime expiration;
   OrderExpiration(symbol, typeTime, expiration);

   g_trade.SetTypeFillingBySymbol(symbol);
   const string comment = StringSubstr((isTest ? ARFT_COMMENT_TEST : ARFT_COMMENT) + setup.key,
                                       0, ARFT_COMMENT_MAX);
   const bool sent = isBuy ? g_trade.BuyStop(lots, entry, symbol, sl, tp, typeTime, expiration, comment)
                           : g_trade.SellStop(lots, entry, symbol, sl, tp, typeTime, expiration, comment);
   if(!RequestAccepted(sent))
     {
      LogError(StringFormat("%s: %s %s odmítnut - %u %s.", setup.key, typeName, symbol,
                            g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
      return(false);
     }

   LogInfo(StringFormat("%s: %s %s %s lot @ %s, SL %s, PT %s #%I64u", setup.key, typeName, symbol,
                        FormatLots(symbol, lots), DoubleToString(entry, digits),
                        DoubleToString(sl, digits), DoubleToString(tp, digits), g_trade.ResultOrder()));
   return(true);
  }

//+------------------------------------------------------------------+
//| Směr obchodu: podle slova Long / Short v názvu záznamu, záložně  |
//| podle polohy cíle vůči vstupu. Vrací +1 nákup, -1 prodej, 0 nic. |
//+------------------------------------------------------------------+
int SetupDirection(const STradeSetup &setup)
  {
   string key = setup.key;
   StringToUpper(key);
   const bool isLong  = StringFind(key, "LONG") >= 0;
   const bool isShort = StringFind(key, "SHORT") >= 0;
   if(isLong != isShort)
      return(isLong ? 1 : -1);
   if(setup.target > setup.entry)
      return(1);
   if(setup.target < setup.entry)
      return(-1);
   return(0);
  }

//+------------------------------------------------------------------+
//| Platnost nového pokynu na serveru (viz PendingDeadline) jako     |
//| pojistka pro případ, že terminál v tu dobu neběží.               |
//|  symbol     - symbol pokynu                                      |
//|  typeTime   - out: typ platnosti                                 |
//|  expiration - out: konec platnosti (čas serveru)                 |
//| Když symbol konkrétní čas nepodporuje, pokyn platí do zrušení a  |
//| maže ho jen expert.                                              |
//+------------------------------------------------------------------+
void OrderExpiration(const string symbol, ENUM_ORDER_TYPE_TIME &typeTime, datetime &expiration)
  {
   typeTime   = ORDER_TIME_GTC;
   expiration = 0;

   const datetime serverNow = TimeTradeServer();
   string         why;
   const datetime expiry    = PendingDeadline(symbol, serverNow, why);
   const long     modes     = SymbolInfoInteger(symbol, SYMBOL_EXPIRATION_MODE);
   if((modes & SYMBOL_EXPIRATION_SPECIFIED) != 0 && expiry > serverNow + ARFT_MIN_EXPIRY_SEC)
     {
      typeTime   = ORDER_TIME_SPECIFIED;
      expiration = expiry;
     }
  }

//====================================================================
// Správa pokynů a pozic (zrušení, OCO, konec seance)
//====================================================================

//+------------------------------------------------------------------+
//| Konec platnosti čekajícího pokynu experta (čas serveru). Jedno   |
//| pravidlo pro platnost na serveru při zadání i pro úklid.         |
//|  symbol - symbol pokynu                                          |
//|  setup  - čas zadání pokynu (čas serveru)                        |
//|  why    - out: důvod konce platnosti pro log                     |
//| Pokyn zadaný před časem zrušení svého dne (pásmo burzy) platí do |
//| něj, pozdější (testovací tlačítko) do úklidu před koncem seance  |
//| symbolu. Dřív než úklid seance nekončí platnost nikdy.           |
//+------------------------------------------------------------------+
datetime PendingDeadline(const string symbol, const datetime setup, string &why)
  {
   const datetime sessionDeadline = SessionDeadline(symbol, setup);
   const datetime setupExchange   = ServerToExchange(setup);
   const datetime cancelExchange  = CancelTimeFor(setupExchange);
   if(setupExchange < cancelExchange)
     {
      const datetime cancelServer = ExchangeToServer(cancelExchange);
      if(cancelServer < sessionDeadline)
        {
         why = "čas zrušení " + TimeToString(cancelExchange, TIME_MINUTES);
         return(cancelServer);
        }
     }
   why = "konec seance";
   return(sessionDeadline);
  }

//+------------------------------------------------------------------+
//| Smaže čekající pokyny experta, kterým skončila platnost (čas     |
//| zrušení, v pátek dřív, nebo konec seance - viz PendingDeadline). |
//+------------------------------------------------------------------+
void ExpirePendings()
  {
   const datetime serverNow = TimeTradeServer();
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OurPendingTicket(i);
      if(ticket == 0)
         continue;
      const string symbol = OrderGetString(ORDER_SYMBOL);
      string why;
      if(!DeadlinePassed(symbol, PendingDeadline(symbol, (datetime)OrderGetInteger(ORDER_TIME_SETUP), why), serverNow))
         continue;
      LogInfo(StringFormat("Ruším pokyn #%I64u %s - %s.", ticket, symbol, why));
      DeleteOrder(ticket);
     }
  }

//+------------------------------------------------------------------+
//| OCO podle otevřených pozic - pojistka k OnTradeTransaction (např.|
//| pokyn se vyplnil, když expert neběžel).                          |
//+------------------------------------------------------------------+
void EnforceOco()
  {
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(OurPositionTicket(i) != 0)
         DeleteOppositePendings(PositionGetString(POSITION_SYMBOL),
                                PositionGetInteger(POSITION_TYPE) == POSITION_TYPE_BUY);
  }

//+------------------------------------------------------------------+
//| OCO: smaže čekající pokyny experta na symbolu v opačném směru,   |
//| než je otevřená pozice.                                          |
//|  symbol    - symbol otevřené pozice                              |
//|  filledBuy - true = otevřel se nákup                             |
//+------------------------------------------------------------------+
void DeleteOppositePendings(const string symbol, const bool filledBuy)
  {
   for(int i = OrdersTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OurPendingTicket(i);
      if(ticket == 0 || OrderGetString(ORDER_SYMBOL) != symbol ||
         IsBuyOrderType(OrderGetInteger(ORDER_TYPE)) == filledBuy)
         continue;
      LogInfo(StringFormat("OCO %s: otevřen %s, ruším protilehlý pokyn #%I64u.",
                           symbol, filledBuy ? "BUY" : "SELL", ticket));
      DeleteOrder(ticket);
     }
  }

//+------------------------------------------------------------------+
//| Zavře pozice experta X minut před koncem obchodní seance symbolu.|
//| Seance se bere ta, ve které pozice vznikla - když terminál v tu  |
//| dobu neběžel, zavře se při nejbližší otevřené seanci.            |
//+------------------------------------------------------------------+
void CloseBeforeSessionEnd()
  {
   const datetime serverNow = TimeTradeServer();
   for(int i = PositionsTotal() - 1; i >= 0; i--)
     {
      const ulong ticket = OurPositionTicket(i);
      if(ticket == 0)
         continue;
      const string symbol = PositionGetString(POSITION_SYMBOL);
      if(!DeadlinePassed(symbol, SessionDeadline(symbol, (datetime)PositionGetInteger(POSITION_TIME)), serverNow))
         continue;
      LogInfo(StringFormat("Konec seance %s - zavírám pozici #%I64u.", symbol, ticket));
      ClosePosition(ticket, symbol);
     }
  }

//--- Nastal čas deadline (čas serveru)? Úklid probíhá jen při otevřené
//--- seanci symbolu - mimo ni by server požadavek stejně odmítl.
bool DeadlinePassed(const string symbol, const datetime deadline, const datetime serverNow)
  {
   return(serverNow >= deadline && InTradeSession(symbol, serverNow));
  }

//--- Smaže čekající pokyn experta
void DeleteOrder(const ulong ticket)
  {
   CheckSweepRequest(g_trade.OrderDelete(ticket), StringFormat("Pokyn #%I64u nelze smazat", ticket));
  }

//--- Zavře pozici experta
void ClosePosition(const ulong ticket, const string symbol)
  {
   g_trade.SetTypeFillingBySymbol(symbol);
   CheckSweepRequest(g_trade.PositionClose(ticket), StringFormat("Pozici #%I64u nelze zavřít", ticket));
  }

//--- Vyhodnotí požadavek úklidu; při neúspěchu zaloguje chybu a úklid
//--- na chvíli pozastaví, aby se neopakoval každou sekundu
void CheckSweepRequest(const bool sent, const string what)
  {
   if(RequestAccepted(sent))
      return;
   LogError(StringFormat("%s - %u %s.", what, g_trade.ResultRetcode(), g_trade.ResultRetcodeDescription()));
   g_sweepPauseUntil = TimeTradeServer() + ARFT_SWEEP_PAUSE_SEC;
  }

//--- Prošel požadavek? CTrade vrací true i při některých odmítnutích,
//--- rozhoduje návratový kód serveru
bool RequestAccepted(const bool sent)
  {
   const uint retcode = g_trade.ResultRetcode();
   return(sent && (retcode == TRADE_RETCODE_DONE || retcode == TRADE_RETCODE_PLACED));
  }

//--- Ticket i-tého pokynu, je-li to čekající pokyn experta (zůstane
//--- vybraný pro OrderGet*), jinak 0
ulong OurPendingTicket(const int index)
  {
   const ulong ticket = OrderGetTicket(index);
   if(ticket == 0 || OrderGetInteger(ORDER_MAGIC) != InpMagic)
      return(0);
   const ENUM_ORDER_TYPE type = (ENUM_ORDER_TYPE)OrderGetInteger(ORDER_TYPE);
   return(type != ORDER_TYPE_BUY && type != ORDER_TYPE_SELL && type != ORDER_TYPE_CLOSE_BY ? ticket : 0);
  }

//--- Ticket i-té pozice, je-li to pozice experta (zůstane vybraná pro
//--- PositionGet*), jinak 0
ulong OurPositionTicket(const int index)
  {
   const ulong ticket = PositionGetTicket(index);
   return(ticket != 0 && PositionGetInteger(POSITION_MAGIC) == InpMagic ? ticket : 0);
  }

//--- Je typ pokynu nákupní?
bool IsBuyOrderType(const long type)
  {
   return(type == ORDER_TYPE_BUY || type == ORDER_TYPE_BUY_LIMIT ||
          type == ORDER_TYPE_BUY_STOP || type == ORDER_TYPE_BUY_STOP_LIMIT);
  }

//--- Čitelný název typu pokynu (ORDER_TYPE_SELL_STOP -> SELL STOP)
string OrderTypeName(const long type)
  {
   string name = EnumToString((ENUM_ORDER_TYPE)type);
   StringReplace(name, "ORDER_TYPE_", "");
   StringReplace(name, "_", " ");
   return(name);
  }

//+------------------------------------------------------------------+
//| Nový obchod (deal): otevření pozice experta spustí OCO, uzavření |
//| se zaloguje i s výsledkem.                                       |
//+------------------------------------------------------------------+
void OnDealAdded(const ulong deal)
  {
   if(!HistoryDealSelect(deal))
      return;
   const string          symbol   = HistoryDealGetString(deal, DEAL_SYMBOL);
   const ENUM_DEAL_ENTRY entry    = (ENUM_DEAL_ENTRY)HistoryDealGetInteger(deal, DEAL_ENTRY);
   const bool            isBuy    = HistoryDealGetInteger(deal, DEAL_TYPE) == DEAL_TYPE_BUY;
   const long            magic    = HistoryDealGetInteger(deal, DEAL_MAGIC);
   const long            position = HistoryDealGetInteger(deal, DEAL_POSITION_ID);
   const long            reason   = HistoryDealGetInteger(deal, DEAL_REASON);
   const double          volume   = HistoryDealGetDouble(deal, DEAL_VOLUME);
   const double          price    = HistoryDealGetDouble(deal, DEAL_PRICE);
   const double          profit   = HistoryDealGetDouble(deal, DEAL_PROFIT) +
                                    HistoryDealGetDouble(deal, DEAL_SWAP) +
                                    HistoryDealGetDouble(deal, DEAL_COMMISSION);
   const int             digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);

   //--- Otevření pozice z pokynu experta -> OCO
   if(entry == DEAL_ENTRY_IN || entry == DEAL_ENTRY_INOUT)
     {
      if(magic != InpMagic)
         return;
      LogInfo(StringFormat("Otevřena pozice %s %s %s lot @ %s.", isBuy ? "BUY" : "SELL", symbol,
                           FormatLots(symbol, volume), DoubleToString(price, digits)));
      DeleteOppositePendings(symbol, isBuy);
      return;
     }

   //--- Uzavření: ruční zavření nese magic 0, o příslušnosti k expertovi
   //--- pak rozhoduje obchod, který pozici otevřel (dotaz do historie se
   //--- dělá jen pro magic 0, cizí magic patří jinému expertovi)
   if(magic != InpMagic && (magic != 0 || !IsOurPositionId(position)))
      return;
   LogInfo(StringFormat("Uzavřena pozice %s %s lot @ %s (%s), výsledek %.2f %s.", symbol,
                        FormatLots(symbol, volume), DoubleToString(price, digits),
                        DealReasonText(reason), profit, AccountInfoString(ACCOUNT_CURRENCY)));
  }

//--- Otevřel pozici positionId tento expert? (podle vstupního obchodu)
bool IsOurPositionId(const long positionId)
  {
   if(positionId <= 0 || !HistorySelectByPosition(positionId))
      return(false);
   for(int i = HistoryDealsTotal() - 1; i >= 0; i--)
     {
      const ulong deal = HistoryDealGetTicket(i);
      if(HistoryDealGetInteger(deal, DEAL_ENTRY) == DEAL_ENTRY_IN)
         return(HistoryDealGetInteger(deal, DEAL_MAGIC) == InpMagic);
     }
   return(false);
  }

//--- Čitelný důvod uzavření pozice
string DealReasonText(const long reason)
  {
   switch((int)reason)
     {
      case DEAL_REASON_SL:     return("SL");
      case DEAL_REASON_TP:     return("PT");
      case DEAL_REASON_EXPERT: return("expert");
      case DEAL_REASON_SO:     return("stop out");
      case DEAL_REASON_CLIENT:
      case DEAL_REASON_MOBILE:
      case DEAL_REASON_WEB:    return("ručně");
     }
   return("jiný důvod");
  }

//+------------------------------------------------------------------+
//| Pokyn přesunut do historie: zaloguje zrušení (expertem i ručně), |
//| vypršení platnosti a odmítnutí čekajícího pokynu experta.        |
//+------------------------------------------------------------------+
void OnOrderArchived(const ulong order)
  {
   if(!HistoryOrderSelect(order) || HistoryOrderGetInteger(order, ORDER_MAGIC) != InpMagic)
      return;
   const ENUM_ORDER_STATE state = (ENUM_ORDER_STATE)HistoryOrderGetInteger(order, ORDER_STATE);
   const string what = StringFormat("Pokyn #%I64u %s %s", order,
                                    OrderTypeName(HistoryOrderGetInteger(order, ORDER_TYPE)),
                                    HistoryOrderGetString(order, ORDER_SYMBOL));
   if(state == ORDER_STATE_CANCELED)
      LogInfo(what + " zrušen.");
   else if(state == ORDER_STATE_EXPIRED)
      LogInfo(what + " vypršel.");
   else if(state == ORDER_STATE_REJECTED)
      LogWarn(what + " odmítnut.");
  }

//====================================================================
// Obchodní pomůcky (povolení, ceny, objem)
//====================================================================

//--- Smí expert teď obchodovat? reason - out: proč ne
bool TradingAllowed(string &reason)
  {
   reason = "";
   if(!TerminalInfoInteger(TERMINAL_CONNECTED))
      reason = "terminál není připojen k serveru";
   else if(!TerminalInfoInteger(TERMINAL_TRADE_ALLOWED))
      reason = "vypnuté Algo Trading v terminálu";
   else if(!MQLInfoInteger(MQL_TRADE_ALLOWED))
      reason = "expert nemá povolené obchodování (vlastnosti experta)";
   else if(!AccountInfoInteger(ACCOUNT_TRADE_EXPERT))
      reason = "účet nepovoluje obchodování expertů";
   return(reason == "");
  }

//--- Lze na symbolu zadat stop pokyn v daném směru? reason - out: proč ne
bool SymbolTradable(const string symbol, const bool isBuy, string &reason)
  {
   reason = "";
   const ENUM_SYMBOL_TRADE_MODE mode = (ENUM_SYMBOL_TRADE_MODE)SymbolInfoInteger(symbol, SYMBOL_TRADE_MODE);
   if(mode == SYMBOL_TRADE_MODE_DISABLED || mode == SYMBOL_TRADE_MODE_CLOSEONLY)
      reason = "obchodování symbolu je zakázané";
   else if(isBuy && mode == SYMBOL_TRADE_MODE_SHORTONLY)
      reason = "symbol povoluje jen prodej";
   else if(!isBuy && mode == SYMBOL_TRADE_MODE_LONGONLY)
      reason = "symbol povoluje jen nákup";
   else if((SymbolInfoInteger(symbol, SYMBOL_ORDER_MODE) & SYMBOL_ORDER_STOP) == 0)
      reason = "symbol nepovoluje stop pokyny";
   return(reason == "");
  }

//+------------------------------------------------------------------+
//| Aktuální cena symbolu; u symbolu právě přidaného do Market Watch |
//| počká na první tick i na hodnotu ticku.                          |
//|  symbol   - obchodovaný symbol                                   |
//|  deadline - do kdy čekat (GetTickCount64)                        |
//|  tick     - out: tick přečtený až po dorazení dat                |
//| Hodnota ticku křížového páru (NZDJPY na účtu v USD) potřebuje    |
//| kurz převodního páru (USDJPY). Terminál ho po SymbolSelect načte |
//| sám, data ale dorazí až za desítky ms - do té doby je hodnota    |
//| ticku 0, i když bid/ask symbolu už známé jsou. Vrací false jen   |
//| při chybějící ceně; chybějící hodnotu ticku zaloguje CalcLot.    |
//+------------------------------------------------------------------+
bool WaitForSymbolData(const string symbol, const ulong deadline, MqlTick &tick)
  {
   for(;;)
     {
      const bool hasPrice = SymbolInfoTick(symbol, tick) && tick.bid > 0.0 && tick.ask > 0.0;
      if((hasPrice && LossTickValue(symbol) > 0.0) || GetTickCount64() >= deadline)
         return(hasPrice);
      Sleep(ARFT_DATA_POLL_MS);
     }
  }

//--- Cena zaokrouhlená na velikost ticku a počet desetinných míst symbolu
double NormalizePrice(const string symbol, const double price)
  {
   const double tickSize = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   const int    digits   = (int)SymbolInfoInteger(symbol, SYMBOL_DIGITS);
   const double rounded  = tickSize > 0.0 ? MathRound(price / tickSize) * tickSize : price;
   return(NormalizeDouble(rounded, digits));
  }

//--- Počet desetinných míst objemu podle kroku objemu symbolu
int VolumeDigits(const string symbol)
  {
   const double step = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   if(step <= 0.0 || step >= 1.0)
      return(step > 0.0 ? 0 : 2);
   return((int)MathCeil(-MathLog10(step) - ARFT_LOTSTEP_EPS));
  }

//--- Objem jako text s přesností kroku objemu
string FormatLots(const string symbol, const double lots)
  {
   return(DoubleToString(lots, VolumeDigits(symbol)));
  }

//--- Hodnota ticku v měně účtu pro ztrátovou stranu (u křížových párů se
//--- od TICK_VALUE liší), záložně TICK_VALUE; 0 = data zatím chybí
double LossTickValue(const string symbol)
  {
   const double lossValue = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE_LOSS);
   return(lossValue > 0.0 ? lossValue : SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_VALUE));
  }

//+------------------------------------------------------------------+
//| Ztráta na 1 lot při zásahu SL v měně účtu.                       |
//|  symbol     - obchodovaný symbol                                 |
//|  slDistance - vzdálenost SL od vstupu v ceně (> 0)               |
//| Vrací 0, když chybí hodnota nebo velikost ticku.                 |
//+------------------------------------------------------------------+
double LossPerLot(const string symbol, const double slDistance)
  {
   const double tickValue = LossTickValue(symbol);
   const double tickSize  = SymbolInfoDouble(symbol, SYMBOL_TRADE_TICK_SIZE);
   if(tickValue <= 0.0 || tickSize <= 0.0)
      return(0.0);
   return(slDistance / tickSize * tickValue);
  }

//+------------------------------------------------------------------+
//| Objem z rizika: ztráta na SL = InpRiskPercent % zůstatku.        |
//|  symbol     - obchodovaný symbol                                 |
//|  slDistance - vzdálenost SL od vstupu v ceně                     |
//|  reason     - out: proč objem nelze použít                       |
//| Zaokrouhluje se DOLŮ na krok objemu, aby riziko nepřeteklo; když |
//| nestačí ani nejmenší lot, vrací 0.                               |
//+------------------------------------------------------------------+
double CalcLot(const string symbol, const double slDistance, string &reason)
  {
   reason = "";
   const double minLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MIN);
   const double maxLot  = SymbolInfoDouble(symbol, SYMBOL_VOLUME_MAX);
   const double step    = SymbolInfoDouble(symbol, SYMBOL_VOLUME_STEP);
   const double balance = AccountInfoDouble(ACCOUNT_BALANCE);
   if(balance <= 0.0 || step <= 0.0 || slDistance <= 0.0)
     {
      reason = "chybí data pro výpočet objemu";
      return(0.0);
     }

   //--- Hodnota ticku chybí, když ani po čekání (WaitForSymbolData)
   //--- nedorazil kurz pro přepočet měn - do logu se uvede, který
   const double lossPerLot = LossPerLot(symbol, slDistance);
   if(lossPerLot <= 0.0)
     {
      reason = StringFormat("chybí hodnota ticku %s pro přepočet %s na %s", symbol,
                            SymbolInfoString(symbol, SYMBOL_CURRENCY_PROFIT),
                            AccountInfoString(ACCOUNT_CURRENCY));
      return(0.0);
     }

   //--- Zaokrouhlení dolů na krok objemu (tolerance srovná chybu
   //--- plovoucí čárky, např. 0.29 / 0.01 = 28.999999999999996)
   double lot = MathFloor(balance * InpRiskPercent / 100.0 / lossPerLot / step + ARFT_LOTSTEP_EPS) * step;

   //--- Ořez na maximum symbolu; VOLUME_MAX nemusí být násobkem kroku
   if(maxLot > 0.0 && lot > maxLot)
      lot = MathFloor(maxLot / step + ARFT_LOTSTEP_EPS) * step;

   if(lot < minLot)
     {
      reason = StringFormat("min. lot %s by znamenal riziko %.2f %%", FormatLots(symbol, minLot),
                            minLot * lossPerLot / balance * 100.0);
      return(0.0);
     }
   return(NormalizeDouble(lot, VolumeDigits(symbol)));
  }

//====================================================================
// Vstupní soubor (kernel32) a YAML
//====================================================================

//--- Cesta k souboru dne: <adresář>\RRRRMMDD.yaml (datum v pásmu burzy)
string InputFilePath(const datetime exchangeTime)
  {
   string dir = InpInputDir;
   const string last = StringSubstr(dir, StringLen(dir) - 1);
   if(dir != "" && last != "\\" && last != "/")
      dir += "\\";
   return(dir + StringFormat("%08d.yaml", DayKey(exchangeTime)));
  }

//+------------------------------------------------------------------+
//| Načte textový soubor (UTF-8) mimo sandbox MT5 přes kernel32.dll. |
//|  path  - úplná cesta k souboru                                   |
//|  text  - out: obsah souboru                                      |
//|  error - out: popis chyby                                        |
//+------------------------------------------------------------------+
bool ReadTextFile(const string path, string &text, string &error)
  {
   text  = "";
   error = "";
   //--- Bez povoleného importu DLL by volání WinAPI expert zastavilo
   if(!MQLInfoInteger(MQL_DLLS_ALLOWED))
     {
      error = "není povolen import DLL";
      return(false);
     }

   const long handle = CreateFileW(path, ARFT_GENERIC_READ, ARFT_FILE_SHARE_READ_WRITE, 0,
                                   ARFT_OPEN_EXISTING, ARFT_FILE_ATTRIBUTE_NORMAL, 0);
   if(handle == ARFT_INVALID_HANDLE)
     {
      const uint code = kernel32::GetLastError();
      if(code == ARFT_ERROR_FILE_NOT_FOUND)
         error = "soubor neexistuje";
      else if(code == ARFT_ERROR_PATH_NOT_FOUND)
         error = "adresář neexistuje (je disk připojen?)";
      else if(code == ARFT_ERROR_ACCESS_DENIED)
         error = "přístup odepřen";
      else
         error = StringFormat("chyba WinAPI %u", code);
      return(false);
     }

   //--- Celý soubor se načte najednou; velikost je omezená, YAML je malý
   long size = 0;
   bool ok = GetFileSizeEx(handle, size) != 0 && size >= 0 && size <= ARFT_MAX_FILE_SIZE;
   uchar buffer[];
   uint bytesRead = 0;
   if(ok && size > 0)
     {
      ArrayResize(buffer, (int)size);
      ok = ReadFile(handle, buffer, (uint)size, bytesRead, 0) != 0 && bytesRead == (uint)size;
     }
   CloseHandle(handle);
   if(!ok)
     {
      error = StringFormat("soubor nelze přečíst (velikost %I64d B, max %d B)", size, ARFT_MAX_FILE_SIZE);
      return(false);
     }

   //--- UTF-8 -> string; případný BOM na začátku se zahodí
   if(bytesRead > 0)
      text = CharArrayToString(buffer, 0, (int)bytesRead, CP_UTF8);
   if(StringLen(text) > 0 && StringGetCharacter(text, 0) == 0xFEFF)
      text = StringSubstr(text, 1);
   return(true);
  }

//+------------------------------------------------------------------+
//| Rozebere YAML se seznamem obchodů a volbami souboru:             |
//|   Options:                <- nepovinná sekce voleb (kdekoli)     |
//|     trading: disabled     <- enabled / disabled                  |
//|   GBPUSD Short+:          <- řádek bez odsazení = nový obchod    |
//|     symbol: GBPUSD        <- odsazené řádky = vlastnosti obchodu |
//|     entry_price: 1.3296                                          |
//|     target_price: 1.32612                                        |
//|  text    - obsah souboru                                         |
//|  setups  - out: obchody ze souboru, neověřené (ValidateSetups)   |
//|  options - out: volby ze sekce Options (bez ní se obchoduje)     |
//| Podporuje jen tento plochý tvar (komentáře #, uvozovky, CRLF).   |
//+------------------------------------------------------------------+
void ParseYaml(const string text, STradeSetup &setups[], SFileOptions &options)
  {
   ArrayResize(setups, 0);
   options.trading = true;
   string lines[];
   const int lineCount = StringSplit(text, '\n', lines);
   int  current   = -1;    // index rozebíraného obchodu, -1 = žádný
   bool inOptions = false; // odsazené řádky patří do sekce Options

   for(int i = 0; i < lineCount; i++)
     {
      string line = StripComment(lines[i]);
      StringReplace(line, "\r", "");
      const string trimmed = Trim(line);
      if(trimmed == "")
         continue;

      //--- Klíč je vše před první dvojtečkou (hodnota může dvojtečku obsahovat)
      const int colon = StringFind(trimmed, ":");
      if(colon <= 0)
        {
         LogWarn(StringFormat("YAML řádek %d nerozpoznán: %s", i + 1, trimmed));
         continue;
        }
      const string key   = Unquote(Trim(StringSubstr(trimmed, 0, colon)));
      const string value = Unquote(Trim(StringSubstr(trimmed, colon + 1)));
      //--- Klíče se porovnávají bez ohledu na velikost písmen
      string field = key;
      StringToLower(field);

      //--- Řádek bez odsazení zakládá sekci Options nebo nový obchod
      const ushort first = StringGetCharacter(line, 0);
      if(first != ' ' && first != '\t')
        {
         inOptions = field == "options";
         if(inOptions)
            continue;
         current = ArraySize(setups);
         ArrayResize(setups, current + 1);
         setups[current].key    = key;
         setups[current].symbol = "";
         setups[current].entry  = 0.0;
         setups[current].target = 0.0;
         continue;
        }

      //--- Volby souboru; neznámé volby se ignorují. Neznámá hodnota
      //--- trading se zaloguje a z opatrnosti se neobchoduje.
      if(inOptions)
        {
         if(field == "trading")
           {
            options.trading = StringCompare(value, "enabled", false) == 0;
            if(!options.trading && StringCompare(value, "disabled", false) != 0)
               LogError(StringFormat("YAML řádek %d: neznámá hodnota Options trading '%s' (enabled / disabled) - neobchoduje se.",
                                     i + 1, value));
           }
         continue;
        }
      if(current < 0)
         continue;

      //--- Vlastnosti obchodu; neznámé klíče se ignorují
      if(field == "symbol")
         setups[current].symbol = value;
      else if(field == "entry_price")
         setups[current].entry = ParsePrice(value);
      else if(field == "target_price")
         setups[current].target = ParsePrice(value);
     }
  }

//+------------------------------------------------------------------+
//| Odstraní neúplné obchody (zaloguje je) a doplní chybějící symbol |
//| prvním slovem názvu záznamu. Vrací počet platných obchodů.       |
//+------------------------------------------------------------------+
int ValidateSetups(STradeSetup &setups[])
  {
   int valid = 0;
   const int total = ArraySize(setups);
   for(int i = 0; i < total; i++)
     {
      if(setups[i].symbol == "")
        {
         string words[];
         if(StringSplit(setups[i].key, ' ', words) > 0)
            setups[i].symbol = words[0];
        }
      if(setups[i].symbol == "" || setups[i].entry <= 0.0 || setups[i].target <= 0.0)
        {
         LogWarn(StringFormat("YAML záznam '%s' je neúplný (symbol, entry_price, target_price) - přeskočen.",
                              setups[i].key));
         continue;
        }
      if(valid != i)
         setups[valid] = setups[i];
      valid++;
     }
   ArrayResize(setups, valid);
   return(valid);
  }

//--- Cena z textu (tečka i čárka jako desetinný oddělovač); 0 = neplatná.
//--- Platná cena je z číslic a nejvýš jedné desetinné tečky.
double ParsePrice(string text)
  {
   StringReplace(text, ",", ".");
   string digits = text;
   const int dots = StringReplace(digits, ".", "");
   return(dots <= 1 && IsDigits(digits) ? StringToDouble(text) : 0.0);
  }

//--- Odstraní komentář YAML: # na začátku řádku nebo za mezerou, mimo uvozovky
string StripComment(const string line)
  {
   ushort quote = 0;
   const int len = StringLen(line);
   for(int i = 0; i < len; i++)
     {
      const ushort c = StringGetCharacter(line, i);
      if(quote != 0)
        {
         if(c == quote)
            quote = 0;
         continue;
        }
      if(c == '"' || c == '\'')
         quote = c;
      else if(c == '#' && (i == 0 || StringGetCharacter(line, i - 1) == ' ' || StringGetCharacter(line, i - 1) == '\t'))
         return(StringSubstr(line, 0, i));
     }
   return(line);
  }

//--- Odstraní párové uvozovky kolem hodnoty
string Unquote(const string text)
  {
   const int len = StringLen(text);
   if(len >= 2)
     {
      const ushort first = StringGetCharacter(text, 0);
      if((first == '"' || first == '\'') && StringGetCharacter(text, len - 1) == first)
         return(StringSubstr(text, 1, len - 2));
     }
   return(text);
  }

//--- Text bez mezer a tabulátorů na okrajích
string Trim(string text)
  {
   StringTrimLeft(text);
   StringTrimRight(text);
   return(text);
  }

//====================================================================
// Mapování symbolů
//====================================================================

//+------------------------------------------------------------------+
//| Rozebere ruční mapování "GBPUSD=GBPUSD.r;AUDJPY=AUDJPY.r" a      |
//| založí s ním tabulku mapování (nalezené symboly se přidají v     |
//| ResolveSymbol).                                                  |
//|  text    - hodnota vstupu InpSymbolMap                           |
//|  badPair - out: první neplatná dvojice                           |
//+------------------------------------------------------------------+
bool ParseSymbolMap(const string text, string &badPair)
  {
   ArrayResize(g_symbolFrom, 0);
   ArrayResize(g_symbolTo, 0);
   string pairs[];
   const int count = StringSplit(text, ';', pairs);
   for(int i = 0; i < count; i++)
     {
      const string pair = Trim(pairs[i]);
      if(pair == "")
         continue;
      string parts[];
      const bool twoParts = StringSplit(pair, '=', parts) == 2;
      const string from = twoParts ? NormalizeSymbolName(parts[0]) : "";
      const string to   = twoParts ? Trim(parts[1]) : "";
      if(from == "" || to == "")
        {
         badPair = pair;
         return(false);
        }
      AddSymbolMapping(from, to);
     }
   return(true);
  }

//--- Přidá dvojici do tabulky mapování symbolů
void AddSymbolMapping(const string from, const string to)
  {
   const int n = ArraySize(g_symbolFrom);
   ArrayResize(g_symbolFrom, n + 1);
   ArrayResize(g_symbolTo, n + 1);
   g_symbolFrom[n] = from;
   g_symbolTo[n]   = to;
  }

//+------------------------------------------------------------------+
//| Najde symbol MT5 k symbolu ze souboru a přidá ho do Market Watch.|
//|  yamlSymbol - symbol ze souboru (např. GBPUSD, gbp/usd)          |
//|  symbol     - out: symbol brokera (např. GBPUSD.r)               |
//| Pořadí: tabulka mapování (ruční ze vstupu a dříve nalezené) ->   |
//| přesný název -> chytré hledání mezi všemi symboly serveru.       |
//+------------------------------------------------------------------+
bool ResolveSymbol(const string yamlSymbol, string &symbol)
  {
   const string wanted = NormalizeSymbolName(yamlSymbol);

   //--- Ruční mapování ze vstupu nebo dříve nalezený symbol
   for(int i = 0; i < ArraySize(g_symbolFrom); i++)
      if(g_symbolFrom[i] == wanted)
        {
         symbol = g_symbolTo[i];
         return(SymbolSelect(symbol, true));
        }

   //--- Přesný název, jinak chytré hledání
   bool isCustom = false;
   symbol = SymbolExist(yamlSymbol, isCustom) ? yamlSymbol : FindSimilarSymbol(wanted);
   if(symbol == "" || !SymbolSelect(symbol, true))
      return(false);

   AddSymbolMapping(wanted, symbol);
   if(symbol != yamlSymbol)
      LogInfo(StringFormat("Symbol %s namapován na %s.", yamlSymbol, symbol));
   return(true);
  }

//+------------------------------------------------------------------+
//| Chytré hledání symbolu s předponou / příponou brokera            |
//| (GBPUSD -> GBPUSD.r, GBPUSDm, m.GBPUSD, GBPUSD#...).             |
//|  wanted - normalizovaný symbol ze souboru                        |
//| U měnového páru musí sedět základní i kotovaná měna. Přednost má |
//| nejkratší přídavek a symbol, který už je v Market Watch.         |
//+------------------------------------------------------------------+
string FindSimilarSymbol(const string wanted)
  {
   string best = "";
   int bestScore = INT_MAX;
   const bool isPair = StringLen(wanted) == 6;
   const int total = SymbolsTotal(false);
   for(int i = 0; i < total; i++)
     {
      const string name = SymbolName(i, false);
      const string norm = NormalizeSymbolName(name);
      if(StringFind(norm, wanted) < 0)
         continue;
      if(isPair && (SymbolInfoString(name, SYMBOL_CURRENCY_BASE) != StringSubstr(wanted, 0, 3) ||
                    SymbolInfoString(name, SYMBOL_CURRENCY_PROFIT) != StringSubstr(wanted, 3, 3)))
         continue;
      if(SymbolInfoInteger(name, SYMBOL_TRADE_MODE) == SYMBOL_TRADE_MODE_DISABLED)
         continue;

      //--- Skóre: délka přídavku, mírná penalizace symbolu mimo Market Watch
      int score = (StringLen(norm) - StringLen(wanted)) * 2;
      if(!SymbolInfoInteger(name, SYMBOL_SELECT))
         score++;
      if(score < bestScore)
        {
         bestScore = score;
         best = name;
        }
     }
   return(best);
  }

//--- Název symbolu jen z velkých písmen a číslic (gbp/usd -> GBPUSD)
string NormalizeSymbolName(string name)
  {
   StringToUpper(name);
   string result = "";
   const int len = StringLen(name);
   for(int i = 0; i < len; i++)
     {
      const ushort c = StringGetCharacter(name, i);
      if((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9'))
         result += ShortToString(c);
     }
   return(result);
  }

//====================================================================
// Čas: pásmo burzy, čas serveru, seance symbolu
//====================================================================

//+------------------------------------------------------------------+
//| Nastaví časové pásmo burzy. MQL5 nemá databázi pásem, podporují  |
//| se proto vybraná pásma s pravidly letního času USA a EU.         |
//|  name - název pásma (IANA), např. America/New_York               |
//+------------------------------------------------------------------+
bool InitTimezone(const string name)
  {
   const int hour = 3600;
   if(name == "America/New_York")
     { g_tzStdOffset = -5 * hour; g_tzDst = ARFT_DST_US; }
   else if(name == "America/Chicago")
     { g_tzStdOffset = -6 * hour; g_tzDst = ARFT_DST_US; }
   else if(name == "Europe/London")
     { g_tzStdOffset = 0;         g_tzDst = ARFT_DST_EU; }
   else if(name == "Europe/Prague" || name == "Europe/Berlin")
     { g_tzStdOffset = 1 * hour;  g_tzDst = ARFT_DST_EU; }
   else if(name == "UTC")
     { g_tzStdOffset = 0;         g_tzDst = ARFT_DST_NONE; }
   else
      return(false);
   return(true);
  }

//+------------------------------------------------------------------+
//| Posun pásma burzy od UTC (s) v okamžiku gmt, včetně letního času.|
//+------------------------------------------------------------------+
int ZoneOffsetAt(const datetime gmt)
  {
   if(g_tzDst == ARFT_DST_NONE)
      return(g_tzStdOffset);

   MqlDateTime dt;
   TimeToStruct(gmt, dt);
   datetime dstStart, dstEnd;
   if(g_tzDst == ARFT_DST_US)
     {
      //--- 2:00 místního standardního času 2. neděle března až
      //--- 2:00 místního letního času 1. neděle listopadu
      dstStart = NthSunday(dt.year, 3, 2) + 2 * 3600 - g_tzStdOffset;
      dstEnd   = NthSunday(dt.year, 11, 1) + 2 * 3600 - (g_tzStdOffset + 3600);
     }
   else
     {
      //--- 1:00 UTC poslední neděle března až poslední neděle října
      dstStart = NthSunday(dt.year, 3, 0) + 3600;
      dstEnd   = NthSunday(dt.year, 10, 0) + 3600;
     }
   return(gmt >= dstStart && gmt < dstEnd ? g_tzStdOffset + 3600 : g_tzStdOffset);
  }

//+------------------------------------------------------------------+
//| Půlnoc n-té neděle měsíce (n <= 0 = poslední neděle měsíce).     |
//+------------------------------------------------------------------+
datetime NthSunday(const int year, const int month, const int n)
  {
   MqlDateTime dt;
   ZeroMemory(dt);
   dt.year = year;
   dt.mon  = month;
   dt.day  = 1;

   //--- Poslední neděle: od posledního dne měsíce zpět na neděli
   if(n <= 0)
     {
      dt.mon = month % 12 + 1;
      if(month == 12)
         dt.year++;
      const datetime lastDay = StructToTime(dt) - ARFT_DAY_SECONDS;
      MqlDateTime last;
      TimeToStruct(lastDay, last);
      return(lastDay - last.day_of_week * ARFT_DAY_SECONDS);
     }

   //--- n-tá neděle: první neděle měsíce + (n - 1) týdnů
   const datetime firstDay = StructToTime(dt);
   MqlDateTime first;
   TimeToStruct(firstDay, first);
   return(firstDay + ((7 - first.day_of_week) % 7 + (n - 1) * 7) * ARFT_DAY_SECONDS);
  }

//--- GMT -> pásmo burzy
datetime GmtToExchange(const datetime gmt)
  {
   return(gmt + ZoneOffsetAt(gmt));
  }

//--- Aktuální čas v pásmu burzy (z času GMT počítače)
datetime ExchangeNow()
  {
   return(GmtToExchange(TimeGMT()));
  }

//--- Posun času serveru od GMT (s), zaokrouhlený na 15 minut
int ServerGmtOffset()
  {
   return((int)(MathRound((double)(TimeTradeServer() - TimeGMT()) / 900.0) * 900));
  }

//--- Čas serveru -> pásmo burzy
datetime ServerToExchange(const datetime serverTime)
  {
   return(GmtToExchange(serverTime - ServerGmtOffset()));
  }

//--- Pásmo burzy -> čas serveru (letní čas se určí z přibližného GMT)
datetime ExchangeToServer(const datetime exchangeTime)
  {
   const datetime gmt = exchangeTime - ZoneOffsetAt(exchangeTime - g_tzStdOffset);
   return(gmt + ServerGmtOffset());
  }

//--- Den ve tvaru RRRRMMDD (klíč denního zadání i název souboru)
int DayKey(const datetime t)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   return(dt.year * 10000 + dt.mon * 100 + dt.day);
  }

//--- Půlnoc dne, do kterého patří čas t
datetime DayStart(const datetime t)
  {
   return(t - t % ARFT_DAY_SECONDS);
  }

//--- Dnešní čas zrušení čekajících pokynů v pásmu burzy (pátek má vlastní)
datetime CancelTimeFor(const datetime now)
  {
   MqlDateTime dt;
   TimeToStruct(now, dt);
   return(DayStart(now) + (dt.day_of_week == FRIDAY ? g_cancelFridaySec : g_cancelSec));
  }

//--- Čas dne "HH:MM" -> sekundy od půlnoci; -1 = neplatný
int ParseTimeOfDay(const string text)
  {
   string parts[];
   if(StringSplit(Trim(text), ':', parts) != 2)
      return(-1);
   const string hh = Trim(parts[0]);
   const string mm = Trim(parts[1]);
   if(!IsDigits(hh) || !IsDigits(mm) || StringLen(mm) != 2)
      return(-1);
   const int hours   = (int)StringToInteger(hh);
   const int minutes = (int)StringToInteger(mm);
   if(hours > 23 || minutes > 59)
      return(-1);
   return(hours * 3600 + minutes * 60);
  }

//--- Obsahuje text jen číslice (a aspoň jednu)?
bool IsDigits(const string text)
  {
   const int len = StringLen(text);
   for(int i = 0; i < len; i++)
     {
      const ushort c = StringGetCharacter(text, i);
      if(c < '0' || c > '9')
         return(false);
     }
   return(len > 0);
  }

//+------------------------------------------------------------------+
//| Obchodní seance symbolu v čase t (čas serveru,                   |
//| SymbolInfoSessionTrade).                                         |
//|  end - out: konec seance, do které t patří; když t neleží        |
//|        v žádné, konec nejbližší následující seance téhož dne,    |
//|        jinak konec dne                                           |
//| Vrací true, když t leží v seanci.                                |
//+------------------------------------------------------------------+
bool FindSession(const string symbol, const datetime t, datetime &end)
  {
   MqlDateTime dt;
   TimeToStruct(t, dt);
   const datetime dayStart = DayStart(t);
   const int secOfDay = (int)(t - dayStart);
   datetime nextEnd = 0;
   datetime from, to;
   for(uint i = 0; SymbolInfoSessionTrade(symbol, (ENUM_DAY_OF_WEEK)dt.day_of_week, i, from, to); i++)
     {
      const int fromSec = (int)from;
      const int toSec   = (int)to;
      if(secOfDay >= fromSec && secOfDay < toSec)
        {
         end = dayStart + toSec;
         return(true);
        }
      if(fromSec > secOfDay && (nextEnd == 0 || dayStart + toSec < nextEnd))
         nextEnd = dayStart + toSec;
     }
   end = nextEnd > 0 ? nextEnd : dayStart + ARFT_DAY_SECONDS;
   return(false);
  }

//--- Okamžik, kdy se má obchod vzniklý v čase t zavřít (X minut před koncem seance)
datetime SessionDeadline(const string symbol, const datetime t)
  {
   datetime end;
   FindSession(symbol, t, end);
   return(end - InpCloseBeforeSessionEndMin * 60);
  }

//--- Leží čas t (čas serveru) v obchodní seanci symbolu?
bool InTradeSession(const string symbol, const datetime t)
  {
   datetime end;
   return(FindSession(symbol, t, end));
  }

//====================================================================
// Zobrazení v grafu: testovací tlačítko a log přes Comment()
//====================================================================

//--- Vzdálenost přepočtená podle DPI monitoru (px)
int Dpi(const double base)
  {
   return((int)MathRound(base * g_dpiScale));
  }

//+------------------------------------------------------------------+
//| Vytvoří testovací tlačítko. Log vypisuje Comment() vlevo nahoře  |
//| (MT5 ho sám posune pod okno One Click Trading); tlačítko leží    |
//| v prázdných řádcích na začátku komentáře, tedy nad logem.        |
//+------------------------------------------------------------------+
void CreateTestButton()
  {
   ObjectDelete(0, ARFT_BUTTON);
   ObjectCreate(0, ARFT_BUTTON, OBJ_BUTTON, 0, 0, 0);
   ObjectSetString(0, ARFT_BUTTON, OBJPROP_TEXT, "ZADAT OBCHODY ZE SOUBORU (TEST)");
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_FONTSIZE, ARFT_BTN_FONT_SIZE);
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_COLOR, clrWhite);
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_BGCOLOR, clrSteelBlue);
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_BORDER_COLOR, clrLightSteelBlue);
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_XSIZE, Dpi(ARFT_BTN_W));
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_YSIZE, Dpi(ARFT_BTN_H));
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_SELECTABLE, false);
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_HIDDEN, true);
   PlaceTestButton();
  }

//--- Umístí tlačítko; při zobrazeném okně One Click Trading pod něj
void PlaceTestButton()
  {
   g_oneClickShown = ChartGetInteger(0, CHART_SHOW_ONE_CLICK) != 0;
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_XDISTANCE, Dpi(InpButtonX));
   ObjectSetInteger(0, ARFT_BUTTON, OBJPROP_YDISTANCE,
                    Dpi(InpButtonY) + (g_oneClickShown ? Dpi(InpOneClickShift) : 0));
   ChartRedraw();
  }

//--- Přesune tlačítko, když se zapnulo / vypnulo okno One Click Trading
void RelayoutIfNeeded()
  {
   if((ChartGetInteger(0, CHART_SHOW_ONE_CLICK) != 0) != g_oneClickShown)
      PlaceTestButton();
  }

//+------------------------------------------------------------------+
//| Vypíše vlevo nahoře stav (čas burzy, dnešní zadání, počty pokynů |
//| a pozic experta) a log, nejnovější zpráva nahoře. Comment() se   |
//| volá jen při změně textu.                                        |
//+------------------------------------------------------------------+
void ShowComment()
  {
   //--- Počty čekajících pokynů a pozic experta
   int pendings = 0;
   for(int i = OrdersTotal() - 1; i >= 0; i--)
      if(OurPendingTicket(i) != 0)
         pendings++;
   int positions = 0;
   for(int i = PositionsTotal() - 1; i >= 0; i--)
      if(OurPositionTicket(i) != 0)
         positions++;

   //--- Prázdné řádky nahoře nechávají místo pro testovací tlačítko;
   //--- čas jen na minuty, aby se text neměnil každou sekundu
   const datetime now = ExchangeNow();
   const string dayState = g_doneDay == DayKey(now) ? (g_dayState == "" ? "vyřízeno" : g_dayState) : "čeká";
   string text = "";
   for(int i = 0; i < InpButtonLines; i++)
      text += " \n";
   text += StringFormat("AiRobotForexTrader %s | burza %s | zadání %s: %s | zrušení %s | čekající %d | pozice %d",
                        EA_VERSION, TimeToString(now, TIME_MINUTES), InpPlaceTime, dayState,
                        TimeToString(CancelTimeFor(now), TIME_MINUTES), pendings, positions);
   for(int i = 0; i < ArraySize(g_logText) && StringLen(g_logText[i]) > 0; i++)
      text += "\n" + g_logText[i];

   if(text == g_commentText)
      return;
   g_commentText = text;
   Comment(text);
  }

//+------------------------------------------------------------------+
//| Zápis do logu: Expert log (Print) hned, log v grafu při nejbližším|
//| ShowComment. Řádek v grafu začíná časem burzy.                   |
//|  prefix - označení úrovně ("CHYBA: ", "POZOR: " nebo prázdné)    |
//|  text   - zpráva                                                 |
//+------------------------------------------------------------------+
void Log(const string prefix, const string text)
  {
   Print(ARFT_LOG_TAG, prefix, text);

   //--- Starší řádky se posunou dolů, nejstarší vypadne
   const int capacity = ArraySize(g_logText);
   if(capacity == 0)
      return;
   for(int i = capacity - 1; i > 0; i--)
      g_logText[i] = g_logText[i - 1];
   g_logText[0] = TimeToString(ExchangeNow(), TIME_SECONDS) + " " + prefix + text;
  }

void LogInfo(const string text)  { Log("", text); }
void LogWarn(const string text)  { Log("POZOR: ", text); }
void LogError(const string text) { Log("CHYBA: ", text); }
//+------------------------------------------------------------------+
