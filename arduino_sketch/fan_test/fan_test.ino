/* ===========================================================================
 *  4-TEL FAN TEST + HIZ KONTROL (PWM) - ESP32-S3
 * ---------------------------------------------------------------------------
 *  Fan: 12V 0.6A, 4 tel (Kirmizi/Siyah/Mavi/Sari)
 *
 *  ONEMLI: Fan 12V ile beslenir! ESP/powerbank 5V'u YETMEZ.
 *          Ayri bir 12V adaptor (>=0.6A) kullan.
 *
 *  BAGLANTI:
 *    Kirmizi (+12V) -> 12V kaynak (+)
 *    Siyah   (GND)  -> 12V kaynak (-)  VE  ESP GND   (ORTAK TOPRAK!)
 *    Mavi    (PWM)  -> ESP GPIO4   (hiz kontrol, 25kHz)
 *    Sari    (TACH) -> ESP GPIO5   (RPM okuma; GPIO5 -> 10k -> 3V3 pull-up)
 *
 *  NOT: Bu standalone testtir; bu test sirasinda GPIO4/GPIO5'e baska
 *       bir sey bagli OLMASIN. (Final tasarimda pinleri yeniden ayarlariz.)
 *
 *  BEKLENEN: Fan hizi %0 -> %25 -> %50 -> %75 -> %100 dongusunde degisir,
 *            seri monitorde her adimda olculen RPM yazilir.
 * =========================================================================== */

#define PWM_PIN   4     // Mavi tel  -> hiz kontrol
#define TACH_PIN  5     // Sari tel  -> RPM geri bildirim
#define PWM_FREQ  25000 // 4-tel fan standardi: 25 kHz
#define PWM_RES   8     // 8-bit -> duty 0..255

volatile unsigned long tachCount = 0;
void IRAM_ATTR onTach() { tachCount++; }

// --- ESP32 Arduino core 2.x ve 3.x icin uyumlu PWM yardimcilari ---
void pwmInit() {
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcAttach(PWM_PIN, PWM_FREQ, PWM_RES);
#else
  ledcSetup(0, PWM_FREQ, PWM_RES);
  ledcAttachPin(PWM_PIN, 0);
#endif
}
void pwmWrite(int duty) {   // duty 0..255
#if ESP_ARDUINO_VERSION_MAJOR >= 3
  ledcWrite(PWM_PIN, duty);
#else
  ledcWrite(0, duty);
#endif
}

void setup() {
  Serial.begin(115200);
  delay(600);
  Serial.println("\n=== 4-TEL FAN TEST (PWM + TACH) ===");

  pwmInit();
  pinMode(TACH_PIN, INPUT_PULLUP);   // ek olarak 3V3 harici pull-up onerilir
  attachInterrupt(digitalPinToInterrupt(TACH_PIN), onTach, FALLING);

  Serial.println("Fan 12V ile besleniyor mu? Ortak GND var mi? Kontrol et.");
}

int rpmFromCount(unsigned long count, unsigned long ms) {
  // Cogu fan: 2 puls / tur.  RPM = (puls/2) / (sn) * 60
  float rev = count / 2.0;
  float minutes = ms / 60000.0;
  if (minutes <= 0) return 0;
  return (int)(rev / minutes);
}

void runStep(const char* label, int duty) {
  Serial.print(">> Hiz "); Serial.print(label);
  Serial.print("  (duty="); Serial.print(duty); Serial.println(")");
  pwmWrite(duty);
  delay(1500);                 // hiz otursun

  noInterrupts(); tachCount = 0; interrupts();
  unsigned long t0 = millis();
  delay(2000);                 // 2 sn say
  unsigned long c;
  noInterrupts(); c = tachCount; interrupts();

  int rpm = rpmFromCount(c, millis() - t0);
  Serial.print("   Olculen RPM ~ "); Serial.print(rpm);
  Serial.print("   (puls="); Serial.print(c); Serial.println(")");
  if (c == 0 && duty > 0)
    Serial.println("   !! Puls yok: Sari(tach) bagli mi / pull-up var mi / 12V geliyor mu?");
}

void loop() {
  runStep("%0",   0);
  runStep("%25",  64);
  runStep("%50",  128);
  runStep("%75",  191);
  runStep("%100", 255);
  Serial.println("--- dongu tekrar ---\n");
}
