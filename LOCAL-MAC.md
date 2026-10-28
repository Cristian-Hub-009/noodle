# Noodle pentru Mac — versiunea lui Cristi

Această versiune păstrează aplicația nativă, personajele și exercițiile din
proiectul Noodle, publicat de pcybriwsky sub licența MIT. O configurație nouă
pornește pe cronometru, la 20 de minute, fără Claude Code. Setările existente
sunt păstrate; dacă ai folosit deja aplicația, poți alege Settings → Remind me
→ On a timer.

## Aplicația gata compilată — fără unelte de dezvoltare

1. În repository, deschide **Actions → Build local Mac app**.
2. Dacă GitHub afișează **I understand my workflows, go ahead and enable them**,
   activează workflow-urile din fork. Apoi selectează **Build local Mac app →
   Run workflow**, alege ramura `local-macos` (sau `main`, după integrare) și
   apasă **Run workflow**.
3. Deschide o execuție verde și descarcă **Artifacts → Noodle-Mac**.
4. Dezarhivează descărcarea, apoi `Noodle.zip`. Deschide `Noodle.app`.
   Poți păstra aplicația într-un folder propriu; nu trebuie mutată în Applications.
5. Din iconița cu omuleț din bara de meniu, alege **Show one now** pentru probă.
   Folosește **Start**, apoi **Done**. Următoarele notificări sunt pe cronometru.

Necesită macOS 13 sau mai nou. Același fișier funcționează pe Intel și Apple
Silicon. Nu necesită Python, Node.js, Homebrew, Xcode sau Claude Code.

Build-ul din fork are semnătură ad-hoc, fără certificat Developer ID și fără
notarizare Apple. macOS sau politica unui laptop administrat îl pot bloca.
În acest caz cere aprobarea IT; acest proiect nu dezactivează protecțiile Mac-ului.

## Din cod, local

Necesită Apple Command Line Tools cu Swift 5.10 sau mai nou. Dacă sunt deja
instalate, deschide `Start-Noodle.command` prin dublu clic. Dacă o arhivă ZIP
nu păstrează permisiunea de execuție, rulează din folderul proiectului:

```bash
bash Start-Noodle.command
```

Launcherul compilează în `app/build/Noodle.app` și deschide aplicația de acolo.
Nu instalează dependințe, nu cere sudo, nu modifică setările Claude și nu
activează pornirea la login. Păstrează folderul proiectului cât folosești aplicația.

## Setări și oprire

- **Settings → Every**: intervalul notificărilor.
- **Settings → Character**: personajul animat.
- **Settings → Focus**: rotația exercițiilor.
- **Pause for 1 hour** sau **Quit**: pauză sau închidere.
- Configurația și istoricul rămân local în `~/.claude-posture`.
- Calendarul și conectarea la Claude sunt opționale. Aplicația cere confirmare
  înainte de conectarea la Claude; nu este necesară pentru cronometru.

Codul sursă și resursele originale rămân sub licența MIT din `LICENSE`.
