# Atlas Free Inventory

Inventory app for Atlas Free: check items in and out by scanning QR codes or barcodes,
with photos and stock per size.
One static page (`index.html`, plus the logo files); the data is in a shared Supabase database.
Live: https://usenovaos.github.io/atlas-free-inventory/

## Database

Run these in the Supabase SQL Editor, in order, once each:

1. `supabase/setup.sql`: tables, access rules, check-out/check-in
2. `supabase/002_delete_entries.sql`: admins can delete entries (stock is put back)
3. `supabase/003_sizes_photos.sql`: sizes, item photos (private `item-photos` bucket), number-only item numbers

## Brand

Colours, logo and type follow the Atlas Free Brand Book 2025: blue `#2954FF`, black and white text,
Garet Bold all caps with 300 tracking for titles and buttons. Garet is a paid font: the page uses it
when it is installed and falls back to Plus Jakarta Sans (free, similar geometric shapes).
`logo.svg` and `mark.svg` are traced from the brand book's vector logo.
