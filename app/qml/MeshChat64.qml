import QtQuick 2.0
import Sailfish.Silica 1.0
import Sailfish.WebView 1.0

ApplicationWindow {
    initialPage: Component {
        // WebViewPage (not a plain Page) handles the virtual keyboard
        // and orientation correctly — essential for a chat app.
        WebViewPage {
            id: webViewPage

            WebView {
                id: webView
                anchors.fill: parent
                url: "https://meshchat.example.com"   // <- change to your instance

                // Workaround for the Sailfish WebView mishandling
                // width=device-width (fixed devicePixelRatio). Injecting a
                // strict viewport meta after load pins the layout viewport
                // to the real screen width. A ~1-2 px overshoot on the right
                // edge remains and is cosmetic. Remove if your Gecko build
                // behaves without it.
                onLoadedChanged: {
                    if (loaded) {
                        webView.runJavaScript(
                            "var m=document.querySelector('meta[name=viewport]');" +
                            "if(!m){m=document.createElement('meta');m.name='viewport';" +
                            "document.head.appendChild(m);}" +
                            "m.content='width=device-width, initial-scale=1, " +
                            "maximum-scale=1, user-scalable=no';");
                    }
                }
            }
        }
    }

    cover: Qt.resolvedUrl("cover/CoverPage.qml")

    // Commodore Callback 8020: 480x640, portrait only
    allowedOrientations: Orientation.Portrait
}
