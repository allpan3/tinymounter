# TinyMounter artwork

The user selected the slate-blue TM drive and network symbol on 2026-11-06. The app icon
retains the TM and removes the TinyMounter wordmark below the drive. The menu-bar variants
use the same silhouette as monochrome SVG outlines, without letters. Warning and download
marks preserve the existing status priority.

Assets live in `Assets.xcassets`: `AppIcon.appiconset/AppIcon.png` is the 1024 px master;
the smaller PNGs are standard macOS icon sizes, resized with `sips`. MenuBarDrive,
MenuBarProblem and MenuBarDownloading are template image sets with vector preservation.
The project generator includes the catalog and selects AppIcon for the app target.

The raster was edited from the user-supplied image using the built-in imagegen tool.
The service rejected transparent output, so the delivered master has a white background.
Final prompt:

> Edit supplied selected TinyMounter logo into a square app icon. Preserve its design
> faithfully: slate-blue trapezoidal drive, white TM monogram on drive, silver rounded
> front with dark indicator slot, network stem and central node and horizontal line
> beneath. Remove the large TinyMounter wordmark below the graphic. Keep TM on drive.
> Center and enlarge remaining drive-and-network symbol to approximately 80% of canvas
> width, balanced top and bottom margins. Same colors, proportions and clean smooth
> shapes. Pure white background. No new elements, no extra lettering, no mockup, no
> border, no shadows outside graphic. Output 1024x1024 PNG.
