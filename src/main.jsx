import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { Capacitor } from '@capacitor/core'
import './index.css'
import App from './App.jsx'
import { registerServiceWorker } from './push.js'

// Appliqué avant le premier rendu pour éviter un saut visuel : l'enveloppe
// native est réellement bord à bord, contrairement au site/PWA qui conserve
// volontairement sa marge de présentation.
if (typeof document !== 'undefined' && Capacitor.isNativePlatform()) {
  document.documentElement.dataset.nativePlatform = Capacitor.getPlatform()
}

createRoot(document.getElementById('root')).render(
  <StrictMode>
    <App />
  </StrictMode>,
)

// Enregistre le service worker (PWA + notifications push). Sans effet si non supporté.
if (typeof window !== 'undefined') {
  window.addEventListener('load', () => {
    registerServiceWorker()
  })
}
