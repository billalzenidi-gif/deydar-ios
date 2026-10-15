// Script injecté dans le site au chargement de chaque page (avant ses propres scripts) :
// - window.DeydarNative : pont vers l'app (connexion Apple et Google natives, vibration),
// - navigator.geolocation et navigator.permissions branchés sur CoreLocation (une seule demande d'autorisation, celle d'iOS),
// - navigator.share branché sur la feuille de partage iOS,
// - notifications push (DeydarNative.push : autorisation et jeton APNs, inscrits ensuite par le site),
// - au premier lancement, la langue du site = celle du téléphone (si Deydar la propose).
import Foundation

enum NativeBridge {
    static let handlerName = "deydar"

    static func script(geoState: String) -> String {
        source
            .replacingOccurrences(of: "__LANG__", with: AppConfig.deviceLanguage)
            .replacingOccurrences(of: "__VERSION__", with: AppConfig.version)
            .replacingOccurrences(of: "__GEOSTATE__", with: geoState)
    }

    private static let source = #"""
    (function () {
      if (window.DeydarNative) return;
      var bridge = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.deydar;
      if (!bridge) return;

      try {
        if (!localStorage.getItem('dd_lang')) { localStorage.setItem('dd_lang', '__LANG__'); localStorage.setItem('dd_lang_v', '2'); }
      } catch (e) {}

      var pending = {}, seq = 0;
      function call(type, data) {
        return new Promise(function (resolve, reject) {
          var id = ++seq;
          pending[id] = { resolve: resolve, reject: reject };
          var msg = data || {};
          msg.type = type; msg.id = id;
          bridge.postMessage(msg);
        });
      }
      window.__ddNativeResolve = function (id, ok, payload) {
        var p = pending[id];
        if (!p) return;
        delete pending[id];
        if (ok) p.resolve(payload); else p.reject(new Error(payload || 'error'));
      };
      window.DeydarNative = {
        platform: 'ios',
        version: '__VERSION__',
        googleSignIn: function () { return call('google'); },
        // Se connecter avec Apple (app 2.0+) → { identityToken, authorizationCode, nonce, user, email, givenName, familyName }
        appleSignIn: function () { return call('apple'); },
        // Notifications push : 'status' | 'refresh' | 'register' → { status, token?, env? }
        push: function (action) { return call('push', { action: action || 'status' }); },
        haptic: function () { bridge.postMessage({ type: 'haptic' }); },
        // Déconnexion du site : l'app oublie l'identifiant Apple mémorisé (sans réponse).
        appleSignedOut: function () { bridge.postMessage({ type: 'appleSignedOut' }); }
      };

      // navigator.share → feuille de partage iOS (textes et liens ; pas de fichiers).
      function share(data) {
        var d = data || {}, link = '';
        try { if (d.url) link = String(new URL(String(d.url), location.href)); } catch (e) { return Promise.reject(new TypeError('Invalid URL')); }
        var msg = { title: d.title ? String(d.title) : '', text: d.text ? String(d.text) : '', url: link };
        if (!msg.title && !msg.text && !msg.url) return Promise.reject(new TypeError('Nothing to share'));
        return call('share', msg).then(function () { return undefined; }, function (e) {
          var err = new Error((e && e.message) || 'Share canceled'); err.name = 'AbortError'; throw err;
        });
      }
      function canShare(d) { return !!(d && (d.title || d.text || d.url)) && !(d.files && d.files.length); }
      try { Object.defineProperty(navigator, 'share', { value: share, configurable: true, writable: true }); } catch (e) { navigator.share = share; }
      try { Object.defineProperty(navigator, 'canShare', { value: canShare, configurable: true, writable: true }); } catch (e) {}

      window.__ddGeoState = '__GEOSTATE__';
      var watchers = {}, gseq = 0;
      function geoRequest(watch, success, error, options) {
        var id = ++gseq, o = options || {};
        watchers[id] = { success: success, error: error, watch: watch };
        var timeout = Number(o.timeout); if (!isFinite(timeout) || timeout <= 0) timeout = 30000;
        var maxAge = Number(o.maximumAge); if (!isFinite(maxAge) || maxAge < 0) maxAge = 0;
        bridge.postMessage({ type: 'geo', id: id, watch: watch, highAccuracy: !!o.enableHighAccuracy,
          timeout: Math.min(timeout, 120000), maximumAge: Math.min(maxAge, 86400000) });
        return id;
      }
      window.__ddGeo = function (id, pos, err) {
        var w = watchers[id];
        if (!w) return;
        if (!w.watch) delete watchers[id];
        if (pos) {
          if (typeof w.success === 'function') w.success({
            coords: { latitude: pos.lat, longitude: pos.lng, accuracy: pos.acc, altitude: null, altitudeAccuracy: null, heading: null, speed: null },
            timestamp: Date.now()
          });
        } else if (typeof w.error === 'function') {
          w.error({ code: err.code, message: err.message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
        }
      };
      if (navigator.geolocation) {
        navigator.geolocation.getCurrentPosition = function (s, e, o) { geoRequest(false, s, e, o); };
        navigator.geolocation.watchPosition = function (s, e, o) { return geoRequest(true, s, e, o); };
        navigator.geolocation.clearWatch = function (id) { delete watchers[id]; bridge.postMessage({ type: 'geoClear', id: id }); };
      }
      if (navigator.permissions && navigator.permissions.query) {
        var query = navigator.permissions.query.bind(navigator.permissions);
        navigator.permissions.query = function (d) {
          if (d && d.name === 'geolocation') {
            return Promise.resolve({ name: 'geolocation', state: window.__ddGeoState || 'prompt', onchange: null,
              addEventListener: function () {}, removeEventListener: function () {} });
          }
          return query(d);
        };
      }
    })();
    """#
}
