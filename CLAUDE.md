# Instrukce pro tento projekt

## Dokumentace

- `README.md` průběžně aktualizuj: při každé změně, která mění chování aplikace, ovládání,
  zobrazení v grafu, nastavení, strategii, export, spuštění nebo strukturu
  projektu, uprav odpovídající část `README.md` ve stejném commitu.
- Před commitem zkontroluj, zda `README.md` odpovídá změnám v commitu; pokud úprava není
  potřeba (refaktoring, testy, kosmetika), README neměň.

## Postup po změně kódu v `MQL5/`

1. Zvyš `EA_VERSION` (`#define` nad `#property version`) v `AiRobotForexTrader.mq5` podle
   sekce *Verzování* v `README.md` (oprava +0.01, nová funkce +0.10, zásadní změna +1.00)
   a aktualizuj tam „Aktuální verze“.
2. Dokud neproběhne `/simplify`, kompiluj jen kopii ve scratchpadu, ne v terminálu:
   `MetaEditor64.exe /compile:"<scratchpad>\AiRobotForexTrader.mq5" /inc:"<datový adresář terminálu>\MQL5" /log:"<scratchpad>\compile.log"`
   (log je v UTF-16).
3. Spusť `/simplify` a zapracuj jeho nálezy.
4. Spusť instalaci a kompilaci experta do **všech nainstalovaných MT5**:
   `scripts\deploy.cmd -All`. Skript najde všechny terminály s MetaEditorem a datovým
   adresářem, do každého zkopíruje `MQL5\Experts\AiRobotForexTrader\*.mq5` do
   `<data>\MQL5\Experts\AiRobotForexTrader\` a expert tam zkompiluje. Junction se
   nepoužívá — do terminálu se kopírují jen zdrojové soubory tohoto projektu.
5. Úkol je hotový, až když skript u každého terminálu vypíše `Result: 0 errors`
   a skončí řádkem `Nasazeno do N terminalu.`; chyby kompilace oprav.
6. Commit s novou verzí označ tagem `vX.YY` a tag pushni spolu s commitem.

## Pravidla

- Nepoužívej vlastní indikátory; vše, co se má zobrazit v grafu, kreslí expert sám.
- Zdrojové soubory MQL5 a `.ps1` ukládej v UTF-8 s BOM (MetaEditor i PowerShell 5.1
  jinak špatně načtou češtinu).
