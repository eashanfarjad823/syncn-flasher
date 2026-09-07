package com.syncn.flasher

import android.os.Bundle
import android.util.Log
import io.flutter.embedding.android.FlutterActivity
import io.reactivex.plugins.RxJavaPlugins

class MainActivity : FlutterActivity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)

        // flutter_reactive_ble is built on RxAndroidBle, which is built on
        // RxJava 2. When a BLE error arrives after its subscriber has been
        // disposed, RxJava has nowhere to deliver it and — with no global
        // handler installed — rethrows on its own thread, killing the process.
        //
        // That is not a hypothetical: the SyncN firmware deliberately drops the
        // GATT link the moment it accepts Wi-Fi credentials (status 19,
        // GATT_CONN_TERMINATE_PEER_USER) so it can leave provisioning mode and
        // join the network. The resulting UndeliverableException crashed the
        // app every time setup actually SUCCEEDED.
        //
        // A Dart try/catch cannot reach this; the handler has to be installed
        // here, on the Java side.
        RxJavaPlugins.setErrorHandler { error ->
            Log.w("SyncNFlasher", "Undeliverable BLE error (ignored)", error)
        }
    }
}
