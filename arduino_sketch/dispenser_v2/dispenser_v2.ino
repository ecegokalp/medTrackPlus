/* ===========================================================================
 *  MedTrack Plus - Dispenser Firmware v2  (ESP32-S3)  [FULL / MAX98357A]
 * ---------------------------------------------------------------------------
 *  4-carkli "hold-and-reveal" mekanizma. DFPlayer YERINE MAX98357A I2S amfi
 *  ile gomulu WAV (alarm_tr_wav.h) calar. Ayrica mobil "Developer / Device
 *  Control Panel" icin /dev komut + telemetri + log protokolu eklendi.
 *
 *  Donanim:
 *    - ESP32-S3-N16R8 DevKitC-1
 *    - 4 x 28BYJ-48 step motor + ULN2003 surucu   (ESP32'den beslenir - SIRALI calisir)
 *    - 4 x SS49E analog Hall sensor + N52 miknatis (carkin home bolmesinde)
 *    - 1 x HC-SR04 ultrasonik mesafe sensoru       (5V; ECHO bolucu ile 3.3V)
 *    - 1 x cok-fonksiyonlu buton (kisa/uzun/cift)  (GPIO + dahili pull-up)
 *    - 1 x 4 bacakli RGB durum LED'i               (3.3V, PWM)
 *    - 1 x MAX98357A I2S amfi + hoparlor           (gomulu WAV calar)
 *
 *  GUC: Powerbank USB#1 -> ESP32 ; USB#2 -> 5V rayi (HC-SR04 + MAX98357A VIN).
 *       ESP 3V3 -> Hall(x4) + RGB LED + ULN2003 "+".  TUM GND ORTAK.
 *
 *  Kutuphaneler (Library Manager):
 *    - Firebase Arduino Client Library for ESP8266 and ESP32 (Mobizt)
 *    - AccelStepper (Mike McCauley)
 *    - ESP8266Audio (Earle Philhower)   <-- MAX98357A / WAV calma
 *    - (BLE/WiFi/Preferences ESP32 core ile gelir)
 *
 *  ===== PIN HARITASI (HEPSI BENZERSIZ - cakisma yok) =====
 *    Hall   : 1, 2, 3, 4                 (ADC1)
 *    Motor1 : 5, 6, 7, 15
 *    Motor2 : 16, 17, 18, 8
 *    Motor3 : 9, 10, 11, 12
 *    Motor4 : 13, 14, 21, 38
 *    HC-SR04: TRIG=39, ECHO=40
 *    Buton  : 41
 *    LED    : R=42, G=47, B=46
 *    I2S    : BCLK=46, LRC=47, DIN=48    (RGB'den bosalan numarali pinler)
 *    (GPIO43/44 = TX/RX USB-seri, KULLANILMAZ; 19/20 USB; 26-32 flash; 33-37 PSRAM)
 * =========================================================================== */

#include <WiFi.h>
#include <Preferences.h>
#include <AccelStepper.h>
#include <Firebase_ESP_Client.h>
#include "addons/RTDBHelper.h"

#include <BLEDevice.h>
#include <BLEServer.h>
#include <BLEUtils.h>
#include <BLE2902.h>

#include "time.h"

// --- Ses: MAX98357A (I2S) + gomulu WAV ---
#include "AudioFileSourcePROGMEM.h"
#include "AudioGeneratorWAV.h"
#include "AudioOutputI2S.h"
#include "alarm_tr_wav.h"            // alarm_tr_wav[], alarm_tr_wav_len

// ============================ AYARLAR / CREDENTIALS ==========================
#define FIREBASE_DATABASE_URL  "https://medtrack-plus-default-rtdb.europe-west1.firebasedatabase.app"
#define FIREBASE_API_KEY       "AIzaSyDwQprDrrvTWtj9prbHp8NLQk35bpqUi4g"
#define DEVICE_NAME            "MEDTRACK_PLUS"

#define BLE_SERVICE_UUID        "4fafc201-1fb5-459e-8fcc-c5c9c331914b"
#define BLE_CHARACTERISTIC_UUID "beb5483e-36e1-4688-b7f5-ea07361b26a8"

const long  GMT_OFFSET_SEC      = 3 * 3600;   // UTC+3
const int   DAYLIGHT_OFFSET_SEC = 0;
const char* NTP_SERVER          = "pool.ntp.org";

// ============================ PIN HARITASI ==================================
const int HALL_PIN[4] = { 1, 2, 3, 4 };       // ADC1

// 4 x ULN2003 (AccelStepper HALF4WIRE sirasi: IN1, IN3, IN2, IN4)
#define M1_IN1 5
#define M1_IN2 6
#define M1_IN3 7
#define M1_IN4 15
#define M2_IN1 16
#define M2_IN2 17
#define M2_IN3 18
#define M2_IN4 8
#define M3_IN1 9
#define M3_IN2 10
#define M3_IN3 11
#define M3_IN4 12
#define M4_IN1 13
#define M4_IN2 14
#define M4_IN3 21
#define M4_IN4 38

#define HCSR04_TRIG 39
#define HCSR04_ECHO 40                // 5V -> 1k/2k bolucu ile 3.3V

#define BUTTON_PIN 41

// Tek renkli (2 bacakli) durum LED'i: Anot -> 220ohm -> LED_PIN, Katot -> GND. HIGH=yanar.
#define LED_PIN 42
// (Eski RGB pinleri GPIO47 ve GPIO46 artik KULLANILMIYOR - bosta)

// I2S (MAX98357A): hepsi ESP cikisi. GPIO43/44 "TX/RX" (USB-seri) oldugu icin
// KULLANILMAZ; bunun yerine RGB'den bosalan 46/47/48 kullaniliyor (numarali pinler).
#define I2S_BCLK 46
#define I2S_LRC  47
#define I2S_DIN  48

// ============================ TIP TANIMLARI =================================
enum LedMode { LED_OFF, LED_ON, LED_BLINK };   // tek renkli LED: kapali / acik / yanip-sonme

// ============================ MEKANIK PARAMETRELER ==========================
const long  STEPS_PER_SLOT  = 1850;   // <-- KALIBRE ET
const float MOTOR_MAX_SPEED = 900.0;
const float MOTOR_ACCEL     = 600.0;

const int HALL_HIGH_THRESHOLD = 2900;
const int HALL_LOW_THRESHOLD  = 1200;
inline bool hallAtHome(int adc) { return (adc > HALL_HIGH_THRESHOLD || adc < HALL_LOW_THRESHOLD); }

const int PRESENCE_CM = 45;
const unsigned long PRESENCE_TIMEOUT_MS = 30000;

const unsigned long CONFIG_CHECK_INTERVAL    = 15000;
const unsigned long BUZZER_CHECK_INTERVAL    = 2000;
const unsigned long PRESENCE_PUBLISH_INTERVAL= 4000;
const unsigned long DEV_CMD_INTERVAL         = 1000;   // /dev/command poll
const unsigned long DEV_TELEMETRY_INTERVAL   = 800;    // /dev/telemetry yayini
const unsigned long SENSOR_LOG_INTERVAL      = 2000;   // seri monitore sensor logu

// ============================ GLOBAL NESNELER ===============================
AccelStepper stepper[4] = {
  AccelStepper(AccelStepper::HALF4WIRE, M1_IN1, M1_IN3, M1_IN2, M1_IN4),
  AccelStepper(AccelStepper::HALF4WIRE, M2_IN1, M2_IN3, M2_IN2, M2_IN4),
  AccelStepper(AccelStepper::HALF4WIRE, M3_IN1, M3_IN3, M3_IN2, M3_IN4),
  AccelStepper(AccelStepper::HALF4WIRE, M4_IN1, M4_IN3, M4_IN2, M4_IN4)
};

FirebaseData   fbdo;
FirebaseAuth   fbAuth;
FirebaseConfig fbConfig;

Preferences prefs;

// Ses (I2S). audioOut bir kez kurulur; her calmada gecici source+generator.
AudioOutputI2S* audioOut = nullptr;

String DEVICE_ID = "";
bool   wifiOnline = false;

struct Section {
  String name;
  bool   isActive;
  int    pillCount;
  int    schedCount;
  int    schedH[12];
  int    schedM[12];
  bool   verildiToday[12];
};
Section sections[4];

BLEServer*         pServer = nullptr;
BLECharacteristic* pCharacteristic = nullptr;
volatile bool deviceConnected = false;
volatile bool credentialsReceived = false;
String receivedSSID = "", receivedPassword = "";
bool bleMode = false;                 // su an BLE kurulum modunda miyiz
unsigned long wifiDropAt = 0, wifiStableAt = 0;

volatile unsigned long lastBtnEdge = 0;
unsigned long btnDownAt = 0;
bool btnDown = false;
int  btnTapCount = 0;                  // coklu basis sayaci
unsigned long btnLastTapAt = 0;        // son kisa basis zamani
bool btnLedOn = false;                 // tek basisla LED ac/kapa durumu
const unsigned long MULTITAP_WINDOW = 600;  // ms - basislar arasi pencere
const unsigned long LONGPRESS_MS    = 3000; // ms - basili tutma (reset)

unsigned long lastConfigCheck = 0, lastBuzzerCheck = 0, lastPresencePub = 0;
unsigned long lastDevCmdCheck = 0, lastDevTelemetry = 0, lastSensorLog = 0;
int  lastResetDay = -1;

// Dev panel
bool   devStreamOn = false;
double lastDevCmdId = 0;

// ============================ ON-BILDIRIMLER ===============================
void serviceLed();
void disableMotor(int idx);
void devLog(const char* level, const String& msg);

// ============================ TEK RENKLI DURUM LED'i ========================
//  Davranis:
//    BLE / internete baglanma bekleniyor -> hizli yanip soner (LED_BLINK)
//    Internete baglaninca -> 3 kez UZUN yanip soner (ledOnlineSuccess), sonra kapali
//    Buton 1 basis -> ac (LED_ON) / tekrar 1 basis -> kapat (LED_OFF)
LedMode ledMode = LED_OFF;
unsigned long ledBlinkAt = 0;
bool ledPhase = false;
const unsigned long LED_BLINK_INTERVAL = 250;   // ms (hizli blink)

void setLed(LedMode m) { ledMode = m; }

void serviceLed() {
  switch (ledMode) {
    case LED_OFF: digitalWrite(LED_PIN, LOW);  break;
    case LED_ON:  digitalWrite(LED_PIN, HIGH); break;
    case LED_BLINK:
      if (millis() - ledBlinkAt > LED_BLINK_INTERVAL) {
        ledBlinkAt = millis();
        ledPhase = !ledPhase;
        digitalWrite(LED_PIN, ledPhase ? HIGH : LOW);
      }
      break;
  }
}

// Internete baglaninca calistirilir: 3 kez uzun yanip sonme, sonra kapali.
void ledOnlineSuccess() {
  for (int i = 0; i < 3; i++) {
    digitalWrite(LED_PIN, HIGH); delay(600);
    digitalWrite(LED_PIN, LOW);  delay(300);
  }
  setLed(LED_OFF);
}

// ============================ SES (MAX98357A / I2S) =========================
void audioInit() {
  audioOut = new AudioOutputI2S();
  audioOut->SetPinout(I2S_BCLK, I2S_LRC, I2S_DIN);
  audioOut->SetOutputModeMono(true);      // mono sesi her iki kanala
  audioOut->SetGain(0.7);                 // 0.0..1.0
}

// Gomulu WAV'i bloklayarak (yaklasik 6 sn) calar.
void playAlarm() {
  if (!audioOut) return;
  AudioFileSourcePROGMEM file(alarm_tr_wav, alarm_tr_wav_len);
  AudioGeneratorWAV wav;
  if (!wav.begin(&file, audioOut)) return;
  unsigned long t0 = millis();
  while (wav.isRunning()) {
    if (!wav.loop()) { wav.stop(); break; }
    if (millis() - t0 > 12000) { wav.stop(); break; }   // guvenlik kapagi
    serviceLed();
  }
}

// Tek gomulu ses var: sadece "ilac zamani"(1) ve "uyari"(4) icin cal.
void playTrack(int n) {
  if (n == 1 || n == 4) playAlarm();
}

// ============================ HC-SR04 ======================================
long readDistanceCm() {
  digitalWrite(HCSR04_TRIG, LOW);  delayMicroseconds(3);
  digitalWrite(HCSR04_TRIG, HIGH); delayMicroseconds(10);
  digitalWrite(HCSR04_TRIG, LOW);
  long dur = pulseIn(HCSR04_ECHO, HIGH, 30000);
  if (dur == 0) return 999;
  return dur / 58;
}
bool userPresent() { return readDistanceCm() <= PRESENCE_CM; }

// ============================ MOTOR / HOMING ===============================
void disableMotor(int idx) { stepper[idx].disableOutputs(); }

void moveStepsBlocking(int idx, long steps) {
  if (idx < 0 || idx > 3) return;
  stepper[idx].enableOutputs();
  stepper[idx].setMaxSpeed(MOTOR_MAX_SPEED);
  stepper[idx].setAcceleration(MOTOR_ACCEL);
  stepper[idx].move(steps);
  while (stepper[idx].distanceToGo() != 0) { stepper[idx].run(); }
  disableMotor(idx);
}

// Carki ileri dondurup miknatis Hall'in onunden gecene kadar arar.
// Bulununca o nokta = home = konum 0 (yani o bolme "1. bolme" olur).
bool homeWheel(int idx) {
  if (idx < 0 || idx > 3) return false;
  const long MAX_STEPS = STEPS_PER_SLOT * 26;   // tam tur + pay
  long moved = 0;
  unsigned long start = millis();
  stepper[idx].enableOutputs();
  stepper[idx].setMaxSpeed(MOTOR_MAX_SPEED);
  stepper[idx].setSpeed(MOTOR_MAX_SPEED * 0.6);
  while (moved < MAX_STEPS) {
    stepper[idx].runSpeed();
    moved++;
    if ((moved % 4) == 0) {
      int adc = analogRead(HALL_PIN[idx]);
      if (hallAtHome(adc)) {
        stepper[idx].setCurrentPosition(0);     // home = 0 (1. bolme)
        disableMotor(idx);
        return true;
      }
    }
    if ((moved % 200) == 0) {
      delay(0);                                  // watchdog besle / yield (reset onle)
      if (millis() - start > 15000) {            // 15 sn'de bulunamadiysa vazgec
        Serial.printf("[HOME] cark %d: 15sn'de home bulunamadi, geciliyor.\n", idx);
        break;
      }
    }
  }
  disableMotor(idx);
  return false;
}

// "Refill sync": tek cark icin homeWheel ile ayni mantik (miknatis -> 1. bolme).
bool refillSync(int idx) {
  bool ok = homeWheel(idx);
  devLog(ok ? "info" : "error",
         String("refill_sync cark ") + idx + (ok ? " OK (home bulundu)" : " HOME BULUNAMADI"));
  return ok;
}

// Tum carklari SIRAYLA (paralel degil) senkronla. Her cark biter, sonraki baslar.
void syncAllSequential(bool isRefill) {
  for (int i = 0; i < 4; i++) {
    devLog("info", String(isRefill ? "refill_sync_all" : "home_all") + " -> cark " + i + " basliyor");
    bool ok = homeWheel(i);
    devLog(ok ? "info" : "error", String("cark ") + i + (ok ? " senkron OK" : " senkron HATA"));
    delay(150);   // carklar arasinda kisa bekleme (sirali oldugunu netlestirir)
  }
}

// ============================ NVS (offline depolama) =======================
void nvsLoad() {
  prefs.begin("meddata", true);
  for (int i = 0; i < 4; i++) {
    String p = "b" + String(i);
    sections[i].name      = prefs.getString((p + "_nm").c_str(), "");
    sections[i].isActive  = prefs.getBool((p + "_akt").c_str(), false);
    sections[i].pillCount = prefs.getInt((p + "_cnt").c_str(), 0);
    sections[i].schedCount= prefs.getInt((p + "_len").c_str(), 0);
    for (int k = 0; k < sections[i].schedCount && k < 12; k++) {
      sections[i].schedH[k] = prefs.getInt((p + "_a" + String(k) + "h").c_str(), 8);
      sections[i].schedM[k] = prefs.getInt((p + "_a" + String(k) + "m").c_str(), 0);
      sections[i].verildiToday[k] = false;
    }
  }
  prefs.end();
}
void nvsSaveSection(int i) {
  prefs.begin("meddata", false);
  String p = "b" + String(i);
  prefs.putString((p + "_nm").c_str(), sections[i].name);
  prefs.putBool((p + "_akt").c_str(), sections[i].isActive);
  prefs.putInt((p + "_cnt").c_str(), sections[i].pillCount);
  prefs.putInt((p + "_len").c_str(), sections[i].schedCount);
  for (int k = 0; k < sections[i].schedCount && k < 12; k++) {
    prefs.putInt((p + "_a" + String(k) + "h").c_str(), sections[i].schedH[k]);
    prefs.putInt((p + "_a" + String(k) + "m").c_str(), sections[i].schedM[k]);
  }
  prefs.end();
}
void nvsClearAll() { prefs.begin("meddata", false); prefs.clear(); prefs.end(); }

// ============================ BLE PROVISIONING (NON-BLOCKING) ==============
// Flutter (lib/features/ble_provisioning) ile BIREBIR protokol:
//   - Cihaz adi "MEDTRACK..." ile baslar (Flutter bunu tarar)
//   - App characteristic'e {"s":"SSID","p":"PASS"} JSON yazar
//   - Cihaz notify ile "TRYING" / "SUCCESS" / "FAIL" geri bildirir
//   - WiFi MAC = DEVICE_ID; app BT MAC'ten (-2) hesaplayip ayni MAC'i kaydeder
class ServerCallbacks : public BLEServerCallbacks {
  void onConnect(BLEServer* s) override { deviceConnected = true; }
  void onDisconnect(BLEServer* s) override {
    deviceConnected = false;
    if (bleMode) { delay(400); s->getAdvertising()->start(); }   // tekrar yayina basla
  }
};
class CharCallbacks : public BLECharacteristicCallbacks {
  void onWrite(BLECharacteristic* c) override {
    String v = c->getValue().c_str();
    if (v.length() == 0) return;
    FirebaseJson json; FirebaseJsonData ds, dp;
    json.setJsonData(v);
    json.get(ds, "s"); json.get(dp, "p");
    if (ds.success && dp.success) {
      receivedSSID     = ds.stringValue;
      receivedPassword = dp.stringValue;
      credentialsReceived = true;            // gercek baglanma loop()'ta yapilir
    }
  }
};

void startBle() {
  if (bleMode) return;
  bleMode = true;
  setLed(LED_BLINK);
  BLEDevice::init(DEVICE_NAME);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new ServerCallbacks());
  BLEService* service = pServer->createService(BLE_SERVICE_UUID);
  pCharacteristic = service->createCharacteristic(
      BLE_CHARACTERISTIC_UUID,
      BLECharacteristic::PROPERTY_READ | BLECharacteristic::PROPERTY_WRITE | BLECharacteristic::PROPERTY_NOTIFY);
  pCharacteristic->addDescriptor(new BLE2902());
  pCharacteristic->setCallbacks(new CharCallbacks());
  service->start();
  BLEAdvertising* adv = BLEDevice::getAdvertising();
  adv->addServiceUUID(BLE_SERVICE_UUID);
  adv->setScanResponse(true);
  adv->setMinPreferred(0x06);
  adv->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  Serial.println("BLE kurulum modu ACIK (MEDTRACK_PLUS) - app'ten WiFi bekleniyor");
}

void stopBle() {
  if (!bleMode) return;
  BLEDevice::deinit(true);
  bleMode = false;
  pCharacteristic = nullptr;
  pServer = nullptr;
  Serial.println("BLE kapatildi (WiFi online).");
}

void bleNotify(const char* msg) {
  if (deviceConnected && pCharacteristic != nullptr) {
    pCharacteristic->setValue(msg);
    pCharacteristic->notify();
  }
}

// App'ten gelen yeni WiFi bilgisiyle baglan + TRYING/SUCCESS/FAIL feedback.
// Basarili olursa creds kalici kaydedilir (WiFi.persistent(true)).
void connectWithCreds(const String& ssid, const String& pass) {
  Serial.println("[BLE] Yeni ag bilgisi geldi. Deneniyor: " + ssid);
  bleNotify("TRYING");
  WiFi.disconnect(true);
  delay(800);
  WiFi.mode(WIFI_STA);
  delay(300);
  WiFi.begin(ssid.c_str(), pass.c_str());
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 40) {
    delay(500); Serial.print("."); tries++; serviceLed();
  }
  Serial.println();

  if (WiFi.status() == WL_CONNECTED) {
    wifiOnline = true;
    Serial.println("[WiFi] BAGLANDI!  IP: " + WiFi.localIP().toString() +
                   "  RSSI: " + String(WiFi.RSSI()));
    Serial.println("[BLE] app'e SUCCESS + gercek WiFi MAC gonderiliyor...");
    bleNotify(("SUCCESS|" + DEVICE_ID).c_str());   // app dogru MAC'i buradan alir
    delay(1500);                              // app feedback'i alsin
    stopBle();                                // ONCE BLE'yi kapat -> RAM bosalt (Firebase icin sart)
    delay(300);
    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
    firebaseInit();                           // fetchConfig loop'ta ready olunca yapilir
    ledOnlineSuccess();
    devLog("info", "WiFi baglandi (" + ssid + "), online. IP=" + WiFi.localIP().toString());
    Serial.println("[SYS] ONLINE. Device ID: " + DEVICE_ID);
  } else {
    Serial.println("[WiFi] BAGLANAMADI (status=" + String(WiFi.status()) + ") -> FAIL");
    bleNotify("FAIL");
    setLed(LED_BLINK);
  }
}

// ============================ WIFI =========================================
// Acilista kayitli (son) ag ile baglanmayi dener. persistent(true) sayesinde
// son basarili ag NVS'te tutulur, otomatik baglanir.
bool wifiTrySaved() {
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin();                               // kayitli kredansiyel
  int tries = 0;
  while (WiFi.status() != WL_CONNECTED && tries < 16) { delay(500); tries++; serviceLed(); }
  return WiFi.status() == WL_CONNECTED;
}

// ============================ FIREBASE =====================================
void firebaseInit() {
  Serial.println("[FB] Firebase baslatiliyor...");
  fbConfig.api_key      = FIREBASE_API_KEY;
  fbConfig.database_url = FIREBASE_DATABASE_URL;
  fbdo.setBSSLBufferSize(4096, 1024);                 // SSL buffer (kararlilik)
  fbConfig.timeout.wifiReconnect    = 10000;
  fbConfig.timeout.socketConnection = 10000;
  fbConfig.timeout.sslHandshake     = 20000;
  fbConfig.timeout.serverResponse   = 10000;
  Firebase.reconnectWiFi(true);
  if (Firebase.signUp(&fbConfig, &fbAuth, "", "")) Serial.println("[FB] anon signUp OK");
  else Serial.println("[FB] signUp not: " + String(fbConfig.signer.signupError.message.c_str()));
  Firebase.begin(&fbConfig, &fbAuth);
  Serial.println("[FB] Firebase.begin cagrildi. (ready=" + String(Firebase.ready()) + ")");
}

String basePath() { return "/dispensers/" + DEVICE_ID; }

void fetchConfig() {
  if (!wifiOnline || !Firebase.ready()) return;
  String path = basePath() + "/config";
  if (Firebase.RTDB.getJSON(&fbdo, path.c_str())) {
    FirebaseJson& json = fbdo.jsonObject();
    for (int i = 0; i < 4; i++) {
      FirebaseJsonData d;
      String sk = "section_" + String(i);
      bool changed = false;
      if (json.get(d, sk + "/name"))      { if (sections[i].name != d.stringValue) { sections[i].name = d.stringValue; changed = true; } }
      if (json.get(d, sk + "/isActive"))  { if (sections[i].isActive != d.boolValue) { sections[i].isActive = d.boolValue; changed = true; } }
      if (json.get(d, sk + "/pillCount")) { if (sections[i].pillCount != d.intValue) { sections[i].pillCount = d.intValue; changed = true; } }
      FirebaseJsonArray arr;
      if (json.get(d, sk + "/schedule")) {
        d.get<FirebaseJsonArray>(arr);
        int n = arr.size(); if (n > 12) n = 12;
        if (n != sections[i].schedCount) changed = true;
        sections[i].schedCount = n;
        for (int k = 0; k < n; k++) {
          FirebaseJsonData hd, md; FirebaseJson item;
          arr.get(hd, k); hd.get<FirebaseJson>(item);
          int hh = 8, mm = 0;
          if (item.get(md, "h")) hh = md.intValue;
          if (item.get(md, "m")) mm = md.intValue;
          if (sections[i].schedH[k] != hh || sections[i].schedM[k] != mm) changed = true;
          sections[i].schedH[k] = hh; sections[i].schedM[k] = mm;
        }
      }
      if (changed) nvsSaveSection(i);
    }
  }
}

void publishCount(int idx) {
  if (!wifiOnline || !Firebase.ready()) return;
  String p = basePath() + "/config/section_" + String(idx) + "/pillCount";
  Firebase.RTDB.setInt(&fbdo, p.c_str(), sections[idx].pillCount);
}
void pushLog(int idx, const char* type) {
  if (!wifiOnline || !Firebase.ready()) return;
  FirebaseJson j;
  j.set("type", type);
  j.set("section", idx);
  j.set("timestamp", (int)time(nullptr));
  Firebase.RTDB.pushJSON(&fbdo, (basePath() + "/logs").c_str(), &j);
}
void publishPresence(bool present) {
  if (!wifiOnline || !Firebase.ready()) return;
  Firebase.RTDB.setBool(&fbdo, (basePath() + "/presence").c_str(), present);
}

// ============================ /dev: LOG / ACK / TELEMETRI ==================
void devLog(const char* level, const String& msg) {
  Serial.printf("[dev:%s] %s\n", level, msg.c_str());
  if (!wifiOnline || !Firebase.ready()) return;
  FirebaseJson j;
  j.set("ts", (int)time(nullptr));
  j.set("level", level);
  j.set("msg", msg);
  Firebase.RTDB.pushJSON(&fbdo, (basePath() + "/dev/logs").c_str(), &j);
}
void devAck(double id, const String& action, bool ok, const String& msg) {
  if (!wifiOnline || !Firebase.ready()) return;
  FirebaseJson j;
  j.set("id", id);
  j.set("action", action);
  j.set("ok", ok);
  j.set("msg", msg);
  j.set("ts", (int)time(nullptr));
  Firebase.RTDB.setJSON(&fbdo, (basePath() + "/dev/ack").c_str(), &j);
}
void publishDevTelemetry() {
  if (!wifiOnline || !devStreamOn || !Firebase.ready()) return;
  FirebaseJson j, hall, home, pos;
  for (int i = 0; i < 4; i++) {
    int adc = analogRead(HALL_PIN[i]);
    hall.set("s" + String(i), adc);
    home.set("s" + String(i), hallAtHome(adc));
    pos.set("s" + String(i), (int)stepper[i].currentPosition());
  }
  long dist = readDistanceCm();
  j.set("hall", hall);
  j.set("home", home);
  j.set("pos", pos);
  j.set("distance_cm", (int)dist);
  j.set("present", dist <= PRESENCE_CM);
  j.set("wifi", wifiOnline);
  j.set("rssi", (int)WiFi.RSSI());
  j.set("heap", (int)ESP.getFreeHeap());
  j.set("uptime_s", (int)(millis() / 1000));
  j.set("ts", (int)time(nullptr));
  Firebase.RTDB.setJSON(&fbdo, (basePath() + "/dev/telemetry").c_str(), &j);
}

// ============================ ILAC VERME ===================================
void dispense(int idx, bool requirePresence) {
  if (idx < 0 || idx > 3) return;

  if (requirePresence) {
    setLed(LED_ON);
    playTrack(1);                         // "ilac zamani"
    unsigned long t0 = millis();
    while (!userPresent()) {
      serviceLed();
      if (millis() - t0 > PRESENCE_TIMEOUT_MS) {
        pushLog(idx, "no_presence");
        setLed(wifiOnline ? LED_OFF : LED_BLINK);
        return;
      }
      delay(50);
    }
    publishPresence(true);
  }

  setLed(LED_ON);
  moveStepsBlocking(idx, STEPS_PER_SLOT);   // 1 bolme dondur

  if (sections[idx].pillCount > 0) sections[idx].pillCount--;
  nvsSaveSection(idx);
  publishCount(idx);
  pushLog(idx, "auto_dispense");

  setLed(wifiOnline ? LED_OFF : LED_BLINK);

  if (requirePresence) publishPresence(false);
}

// ============================ ZAMAN KONTROLU ===============================
void checkSchedules() {
  struct tm t;
  if (!getLocalTime(&t, 100)) return;
  int day = t.tm_yday, hh = t.tm_hour, mm = t.tm_min;
  if (day != lastResetDay) {
    lastResetDay = day;
    for (int i = 0; i < 4; i++)
      for (int k = 0; k < 12; k++) sections[i].verildiToday[k] = false;
  }
  for (int i = 0; i < 4; i++) {
    if (!sections[i].isActive) continue;
    for (int k = 0; k < sections[i].schedCount; k++) {
      if (!sections[i].verildiToday[k] &&
          sections[i].schedH[k] == hh && sections[i].schedM[k] == mm) {
        sections[i].verildiToday[k] = true;
        dispense(i, true);
      }
    }
  }
}

// ============================ RTDB KOMUT/BUZZER POLL =======================
void pollCommandsAndBuzzer() {
  if (!wifiOnline || !Firebase.ready()) return;

  if (Firebase.RTDB.getJSON(&fbdo, (basePath() + "/commands/dispense").c_str())) {
    FirebaseJson& j = fbdo.jsonObject();
    FirebaseJsonData d;
    static int lastCmdTs = 0;
    int ts = 0, sec = 0;
    if (j.get(d, "timestamp")) ts = d.intValue;
    if (j.get(d, "section"))   sec = d.intValue;
    if (ts != 0 && ts != lastCmdTs) {
      lastCmdTs = ts;
      dispense(sec, true);
    }
  }

  if (Firebase.RTDB.getBool(&fbdo, (basePath() + "/buzzer").c_str())) {
    if (fbdo.boolData()) {
      setLed(LED_BLINK);
      playTrack(4);
      Firebase.RTDB.setBool(&fbdo, (basePath() + "/buzzer").c_str(), false);
      setLed(wifiOnline ? LED_OFF : LED_BLINK);
    }
  }
}

// ============================ /dev KOMUT POLL =============================
void pollDevCommand() {
  if (!wifiOnline || !Firebase.ready()) return;
  if (!Firebase.RTDB.getJSON(&fbdo, (basePath() + "/dev/command").c_str())) return;

  FirebaseJson& j = fbdo.jsonObject();
  FirebaseJsonData d;

  double id = 0; String action = "";
  if (j.get(d, "id"))     id = d.doubleValue;       // ms timestamp -> double
  if (j.get(d, "action")) action = d.stringValue;
  if (id == 0 || id == lastDevCmdId || action.length() == 0) return;
  lastDevCmdId = id;

  int section = 0, steps = 0, slots = 0, track = 1, state = 0; bool on = false;
  if (j.get(d, "section")) section = d.intValue;
  if (j.get(d, "steps"))   steps   = d.intValue;
  if (j.get(d, "slots"))   slots   = d.intValue;
  if (j.get(d, "track"))   track   = d.intValue;
  if (j.get(d, "state"))   state   = d.intValue;
  if (j.get(d, "on"))      on      = d.boolValue;

  devLog("cmd", "action=" + action + " section=" + section);
  bool ok = true; String msg = "ok";

  if (action == "motor_step") {
    moveStepsBlocking(section, steps);
    msg = String("cark ") + section + " " + steps + " adim";
  } else if (action == "motor_slot") {
    moveStepsBlocking(section, (long)slots * STEPS_PER_SLOT);
    msg = String("cark ") + section + " " + slots + " bolme";
  } else if (action == "home") {
    ok = homeWheel(section); msg = ok ? "home OK" : "home bulunamadi";
  } else if (action == "home_all") {
    syncAllSequential(false); msg = "tum carklar sirali home";
  } else if (action == "refill_sync") {
    ok = refillSync(section); msg = ok ? "refill sync OK" : "home bulunamadi";
  } else if (action == "refill_sync_all") {
    syncAllSequential(true); msg = "tum carklar sirali refill sync";
  } else if (action == "dispense") {
    dispense(section, false); msg = String("cark ") + section + " dagitildi";
  } else if (action == "sound") {
    playAlarm(); msg = "ses calindi";
  } else if (action == "led") {
    setLed(state == 0 ? LED_OFF : (state == 1 ? LED_ON : LED_BLINK)); msg = String("led ") + state;
  } else if (action == "stream") {
    devStreamOn = on; msg = on ? "telemetri ACIK" : "telemetri KAPALI";
  } else {
    ok = false; msg = "bilinmeyen komut";
  }

  devAck(id, action, ok, msg);
  devLog(ok ? "info" : "error", "ack: " + msg);
  // hareket sonrasi LED'i normale al (stream komutu LED'i bozmaz)
  if (action != "led" && action != "stream")
    setLed(wifiOnline ? LED_OFF : LED_BLINK);
}

// ============================ BUTON =======================================
void IRAM_ATTR onButtonChange() {
  unsigned long now = millis();
  if (now - lastBtnEdge < 30) return;
  lastBtnEdge = now;
}
void factoryReset() {
  setLed(LED_BLINK);
  playTrack(4);
  nvsClearAll();
  WiFi.disconnect(true, true);
  delay(800);
  ESP.restart();
}
// Buton islevleri:
//   - 1 basis  -> LED ac/kapa (toggle, "calisiyor mu" gostergesi)
//   - 2 basis  -> stok bildir (log)
//   - 3 basis  -> BLE kurulum moduna gec (WiFi yeniden ayarlamak icin)
//   - basili tut (>=3 sn) -> fabrika ayarlarina don (reset)
void serviceButton() {
  bool pressed = (digitalRead(BUTTON_PIN) == LOW);

  // Basildi
  if (pressed && !btnDown) {
    btnDown = true; btnDownAt = millis();
    Serial.println("[BTN] BASILDI");
  }

  // Birakildi
  if (!pressed && btnDown) {
    btnDown = false;
    unsigned long held = millis() - btnDownAt;
    Serial.printf("[BTN] BIRAKILDI (%lu ms)\n", held);
    if (held >= LONGPRESS_MS) {           // BASILI TUTMA -> reset
      btnTapCount = 0;
      Serial.println("[BTN] Basili tutuldu -> FABRIKA AYARLARI (reset)");
      factoryReset();
      return;
    } else {                              // KISA BASIS -> say
      btnTapCount++;
      btnLastTapAt = millis();
    }
  }

  // Coklu-basis penceresi doldu -> degerlendir
  if (btnTapCount > 0 && !btnDown && (millis() - btnLastTapAt > MULTITAP_WINDOW)) {
    int taps = btnTapCount;
    btnTapCount = 0;

    if (taps >= 3) {                      // 3+ BASIS -> BLE modu
      Serial.println("[BTN] 3x basis -> BLE kurulum modu aciliyor");
      startBle();                         // zaten aciksa no-op
    } else if (taps == 2) {               // 2 BASIS -> stok bildir
      Serial.println("[BTN] 2x basis -> stok bildir");
      pushLog(0, "stock_report");
    } else {                              // 1 BASIS -> LED ac/kapa
      btnLedOn = !btnLedOn;
      Serial.println(String("[BTN] 1x basis -> LED ") + (btnLedOn ? "ACIK" : "KAPALI"));
      setLed(btnLedOn ? LED_ON : LED_OFF);
    }
  }
}

// ============================ SETUP =======================================
void setup() {
  Serial.begin(115200);

  pinMode(LED_PIN, OUTPUT); digitalWrite(LED_PIN, LOW);
  setLed(LED_OFF);

  pinMode(BUTTON_PIN, INPUT_PULLUP);
  attachInterrupt(BUTTON_PIN, onButtonChange, CHANGE);

  pinMode(HCSR04_TRIG, OUTPUT); pinMode(HCSR04_ECHO, INPUT);
  digitalWrite(HCSR04_TRIG, LOW);

  analogReadResolution(12);
  for (int i = 0; i < 4; i++) pinMode(HALL_PIN[i], INPUT);

  for (int i = 0; i < 4; i++) {
    stepper[i].setMaxSpeed(MOTOR_MAX_SPEED);
    stepper[i].setAcceleration(MOTOR_ACCEL);
    stepper[i].disableOutputs();
  }

  audioInit();                         // I2S / MAX98357A

  // --- DEVICE_ID = WiFi STA MAC adresi (eski MedTrack mantigi) ---
  // WiFi.macAddress() ILK cagrida "00:00:00:00:00:00" donebilir; surucu
  // tam baslamadan okunursa sifir gelir. Bu yuzden RETRY ile okuyoruz.
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.persistent(true);
  delay(100);
  DEVICE_ID = WiFi.macAddress();
  int macTry = 0;
  while ((DEVICE_ID == "00:00:00:00:00:00" || DEVICE_ID.length() == 0) && macTry < 6) {
    delay(500);
    WiFi.mode(WIFI_STA);
    DEVICE_ID = WiFi.macAddress();
    macTry++;
  }
  Serial.println("========================================");
  Serial.println("  Device ID (MAC): " + DEVICE_ID);
  Serial.println("  Uygulamada 'MAC ile cihaz ekle' kismina");
  Serial.println("  bu MAC adresini gir.");
  Serial.println("========================================");

  nvsLoad();

  // WiFi: once kayitli (son) ag ile dene; olmazsa BLE kurulum modu (non-blocking)
  setLed(LED_BLINK);
  if (wifiTrySaved()) {
    wifiOnline = true;
    configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
    firebaseInit();
    fetchConfig();
    devLog("info", "boot: kayitli WiFi ile baglandi (online)");
    ledOnlineSuccess();
  } else {
    wifiOnline = false;
    Serial.println("Kayitli WiFi yok / baglanamadi -> BLE kurulum modu aciliyor");
    startBle();                              // non-blocking; loop() WiFi bilgisini bekler
  }

  // Carklari SIRAYLA home konumuna getir (mutlak konum)
  for (int i = 0; i < 4; i++) homeWheel(i);

  setLed(wifiOnline ? LED_OFF : LED_BLINK);
}

// ============================ LOOP ========================================
void loop() {
  serviceLed();
  serviceButton();

  // --- WiFi/BLE dayaniklilik yonetimi ---
  // Online iken: WiFi'de kal. Internet >5sn giderse offline + BLE kurulum moduna gec.
  // Offline iken WiFi geri gelir (otomatik reconnect) ve 3sn kararli olursa online'a don, BLE'yi kapat.
  bool connected = (WiFi.status() == WL_CONNECTED);
  if (connected) {
    wifiDropAt = 0;
    if (!wifiOnline) {
      if (wifiStableAt == 0) wifiStableAt = millis();
      if (millis() - wifiStableAt > 3000) {       // 3sn kararli
        wifiOnline = true;
        Serial.println(">>> Internet geri geldi (ONLINE).");
        configTime(GMT_OFFSET_SEC, DAYLIGHT_OFFSET_SEC, NTP_SERVER);
        if (bleMode) { stopBle(); firebaseInit(); fetchConfig(); }
        ledOnlineSuccess();
      }
    }
  } else {
    wifiStableAt = 0;
    if (wifiOnline) {
      if (wifiDropAt == 0) wifiDropAt = millis();
      if (millis() - wifiDropAt > 5000) {         // 5sn boyunca yoksa
        wifiOnline = false;
        Serial.println("!!! Internet koptu (OFFLINE) -> BLE kurulum moduna geciliyor.");
        if (!bleMode) startBle();                 // tekrar BLE ac (son ag yine hatirlanir)
      }
    }
  }

  // BLE'den yeni WiFi bilgisi geldiyse baglanmayi dene (TRYING/SUCCESS/FAIL feedback)
  if (credentialsReceived) {
    credentialsReceived = false;
    connectWithCreds(receivedSSID, receivedPassword);
  }

  checkSchedules();

  if (millis() - lastConfigCheck > CONFIG_CHECK_INTERVAL) {
    lastConfigCheck = millis();
    fetchConfig();
  }
  if (millis() - lastBuzzerCheck > BUZZER_CHECK_INTERVAL) {
    lastBuzzerCheck = millis();
    pollCommandsAndBuzzer();
  }
  if (millis() - lastDevCmdCheck > DEV_CMD_INTERVAL) {
    lastDevCmdCheck = millis();
    pollDevCommand();
  }
  if (devStreamOn && millis() - lastDevTelemetry > DEV_TELEMETRY_INTERVAL) {
    lastDevTelemetry = millis();
    publishDevTelemetry();
  }
  if (millis() - lastPresencePub > PRESENCE_PUBLISH_INTERVAL) {
    lastPresencePub = millis();
    publishPresence(userPresent());
  }

  // Periyodik sensor logu (Arduino seri monitor) - hall + ultrasonik + durum
  if (millis() - lastSensorLog > SENSOR_LOG_INTERVAL) {
    lastSensorLog = millis();
    int h0 = analogRead(HALL_PIN[0]), h1 = analogRead(HALL_PIN[1]),
        h2 = analogRead(HALL_PIN[2]), h3 = analogRead(HALL_PIN[3]);
    long d = readDistanceCm();
    Serial.printf("[HB] hall=%d,%d,%d,%d | mesafe=%ldcm | yakin=%d | wifi=%d | fb=%d | ble=%d | heap=%u\n",
                  h0, h1, h2, h3, d, (int)(d <= PRESENCE_CM),
                  (int)wifiOnline, (int)Firebase.ready(), (int)bleMode, (unsigned)ESP.getFreeHeap());
  }

  delay(5);
}
