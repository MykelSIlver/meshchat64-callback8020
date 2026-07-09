Place `MeshChat64.png` (86x86) here.
Generate all four sizes from one source image (e.g. the 512px PWA icon):

    for s in 86 108 128 172; do
      convert icon-512.png -resize ${s}x${s} app/icons/${s}x${s}/MeshChat64.png
    done

Note: Sailfish does not mask icons — what is in the PNG is what you see.
A retro pixel-art icon fits both the C64 theme and the Callback hardware.
