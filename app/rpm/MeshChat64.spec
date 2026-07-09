Name:       MeshChat64

Summary:    C64-styled MeshChat client for the Commodore Callback 8020
Version:    0.1
Release:    1
License:    MIT
URL:        https://meshchat.example.com/
Source0:    %{name}-%{version}.tar.bz2
Requires:   sailfishsilica-qt5 >= 0.10.9
# The WebView runtime stack (Gecko engine + QML components).
# Without these Requires the app installs but the WebView cannot start.
Requires:   sailfish-components-webview-qt5
Requires:   sailfish-components-webview-qt5-popups
Requires:   sailfish-components-webview-qt5-pickers
BuildRequires:  pkgconfig(sailfishapp) >= 1.0.2
BuildRequires:  pkgconfig(Qt5Core)
BuildRequires:  pkgconfig(Qt5Qml)
BuildRequires:  pkgconfig(Qt5Quick)
BuildRequires:  desktop-file-utils

%description
A minimal native SailfishOS WebView shell around a self-hosted MeshChat
instance (MeshChat by saint-cc, https://github.com/saint-cc/meshchat)
with a Commodore 64 presentation layer. Built for the Commodore
Callback 8020 (480x640, SailfishOS 5.x).

%prep
%setup -q -n %{name}-%{version}

%build

%qmake5 

%make_build


%install
%qmake5_install


desktop-file-install --delete-original         --dir %{buildroot}%{_datadir}/applications                %{buildroot}%{_datadir}/applications/*.desktop

%files
%defattr(-,root,root,-)
%{_bindir}/%{name}
%{_datadir}/%{name}
%{_datadir}/applications/%{name}.desktop
%{_datadir}/icons/hicolor/*/apps/%{name}.png
