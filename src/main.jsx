import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import { Capacitor } from '@capacitor/core'
import { Animation, StatusBar, Style } from '@capacitor/status-bar'
import './index.css'
import App from './App.jsx'
import { registerServiceWorker } from './push.js'

async function configureNativeStatusBar() {
  if (!Capacitor.isNativePlatform()) return

  await StatusBar.show({ animation: Animation.None })
  await StatusBar.setOverlaysWebView({ overlay: true })
  await StatusBar.setStyle({ style: Style.Dark })
}

async function bootstrap() {
  try {
    await configureNativeStatusBar()
  } catch {
    // L'application doit rester utilisable même si le réglage natif échoue.
  }

  createRoot(document.getElementById('root')).render(
    <StrictMode>
      <App />
    </StrictMode>,
  )

  if (typeof window !== 'undefined') {
    window.addEventListener('load', () => {
      registerServiceWorker()
    })
  }
}

void bootstrap()
