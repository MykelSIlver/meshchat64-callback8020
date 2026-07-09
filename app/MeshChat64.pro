# MeshChat64 — SailfishOS WebView app for the Commodore Callback 8020
# NOTICE: name must match the .spec Name and .desktop base name.
TARGET = MeshChat64

CONFIG += sailfishapp

SOURCES += src/MeshChat64.cpp

DISTFILES += qml/MeshChat64.qml \
    qml/cover/CoverPage.qml \
    rpm/MeshChat64.spec \
    MeshChat64.desktop

SAILFISHAPP_ICONS = 86x86 108x108 128x128 172x172
