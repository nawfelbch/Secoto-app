import { StrictMode } from 'react'
import { createRoot } from 'react-dom/client'
import './index.css'
import App from './App.jsx'
import { registerServiceWorker } from './push.js'

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
