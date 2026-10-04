# Blueprint: Blockchain Inventory System (BIS)

## 1. Panoramica del Progetto

Questa applicazione Flutter, denominata **Blockchain Inventory System (BIS)**, funge da client mobile per la gestione di un inventario decentralizzato basato su blockchain. L'app permetterà agli utenti di autenticarsi, visualizzare lo stato attuale dell'inventario, consultare lo storico delle modifiche e proporre nuove transazioni (blocchi) alla blockchain.

L'architettura si basa sulla separazione delle responsabilità, utilizzando state management, routing dichiarativo e un'interfaccia utente moderna e reattiva.

## 2. Stile, Design e Funzionalità

### **Design e UI/UX**
*   **Stile:** Moderno, pulito e orientato ai dati, con un forte focus sulla leggibilità e l'interazione rapida.
*   **Font:** `google_fonts` per una tipografia chiara e moderna.
*   **Tema:** Supporto per modalità chiara e scura.

### **Autenticazione**
*   **Login/Logout:** Flusso di autenticazione standard con gestione del token di sessione.
*   **Recupero Password:**
    *   Un percorso a due passaggi (`/login/forgot-password` e `/login/forgot-password/reset-password`).
    *   L'utente inserisce l'email per ricevere un OTP.
    *   L'utente inserisce l'OTP e la nuova password per completare il reset.
*   **Routing Protetto:** `go_router` gestisce i reindirizzamenti per le rotte autenticate e non.

### **Schermata Inventario**
*   **Filtri e Ricerca:** La schermata include filtri a `Chip` e una funzione di ricerca per una facile navigazione nell'inventario. È sempre presente la categoria **"Tutti"**.
*   **Interattività:** Un pulsante "APPLICA" per consolidare le variazioni di quantità e inviarle alla blockchain.

### **Consultazione Blockchain (Storico Transazioni)**
*   **Elenco Blocchi:** La schermata `/chain-log` mostra lo storico completo di tutti i blocchi della chain.
*   **Ricerca:** Un'icona di ricerca nell'AppBar permette di filtrare l'elenco dei blocchi. Inizialmente, la ricerca avverrà per **nome dell'autore** del blocco.
*   **Dettaglio Blocco:** Navigazione al dettaglio di ogni transazione (`/chain-log/:blockId`).

### **Schermata Notifiche**
*   **Layout Compatto:** Le notifiche sono presentate in un elenco ad alta densità, separate da una linea.
*   **Visualizzazione:** Ogni notifica mostra nome dell'articolo, quantità, autore, tempo trascorso e, se presente, una nota.

### **Navigazione Principale (BottomNavigationBar)**

L'applicazione utilizza una barra di navigazione inferiore fissa a 4 sezioni.

1.  **Inventario (Home)** - `/`
2.  **Transazioni** - `/chain-log`
3.  **Notifiche** - `/notifications`
4.  **Profilo** - `/profile`

### **Funzionalità Implementate**
*   **Autenticazione e Navigazione:** Login/Logout, recupero password e routing protetto (`go_router`).
*   **State Management:** `provider` per la gestione dello stato di autenticazione e notifiche.
*   **Modelli Dati:** Definizione di `User`, `Notification`, `Block`, e `ApiResponse`.
*   **Servizio API:** `ApiService` centralizzato per le chiamate di backend.
*   **Navigazione a 4 Schede:** `BottomNavigationBar` fissa con indicatore di notifiche non lette.

## 3. Backend Integration

- **X-App-Token:** Tutte le chiamate API includono un header `X-App-Token` con un valore segreto per l'autenticazione a livello di applicazione.
- **Trasporto API:** Le chiamate al backend usano HTTP non cifrato.
- **Scrittura dei blocchi:** Il backend accetta solo blocchi proposti con almeno tre voti validi di validatori distinti; le richieste legacy del client con sole variazioni di inventario vengono rifiutate.
- **Endpoint per flavor (build-time):**
    - `APP_FLAVOR=prod` (default) usa `API_BASE_URL_PROD`.
    - `APP_FLAVOR=dev` usa `API_BASE_URL_DEV`.
    - `API_BASE_URL` ha precedenza su qualsiasi flavor e forza un endpoint specifico.

## 4. Current Plan

### Bug Fixes

- **Inventory Loading:** Fixed the perpetual loading issue by:
    - Passing the session token in the `checkChainSync` API call.
    - Adding robust `try-catch-finally` error handling to the `_fetchInventory` method.
    - Including the `X-App-Token` in all API requests.
- **`avoid_returning_null_for_void`:** Fixed in `api_service.dart`.
- **`unused_import`:** Fixed in `notification_model.dart`.
- **`deprecated_member_use`:** Fixed in `router.dart`.
- **`use_build_context_synchronously`:** Fixed in `login_screen.dart`, `reset_password_screen.dart`, and `forgot_password_screen.dart`.
- **Improved Login Error Handling:** Implemented user-friendly error messages for different login failure scenarios.
- **`undefined_method`:** Fixed in `api_response.dart` by adding the `error` factory constructor.
