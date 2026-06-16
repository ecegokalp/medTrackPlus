/* ===========================================================================
 *  BUTON TEST - butonu seri monitorden gor
 * ---------------------------------------------------------------------------
 *  Buton basinca seri monitore yazar. Boylece butonun calisip calismadigini
 *  GOZLE gorursun (ana kodda gorunur tepki yok, sadece log/ses var).
 *
 *  Baglanti:
 *    Butonun bir bacagi  -> GPIO 41
 *    CAPRAZ kosedeki bacak -> GND
 *  (Dahili pull-up kullanilir; ek direnc yok.)
 * =========================================================================== */

#define BUTTON_PIN 41

bool lastPressed = false;
unsigned long downAt = 0;
unsigned long lastShort = 0;
int shortCount = 0;

void setup() {
  Serial.begin(115200);
  delay(500);
  pinMode(BUTTON_PIN, INPUT_PULLUP);
  Serial.println("\n=== BUTON TEST ===");
  Serial.println("Butona bas/birak. Hicbir seye basmadan 'BASILI' yaziyorsa,");
  Serial.println("yanlis bacaklari sectin (ayni taraftaki 2 bacak). Capraz bacak sec.");
  Serial.print("Mevcut durum: ");
  Serial.println(digitalRead(BUTTON_PIN) == LOW ? "BASILI (sorun olabilir!)" : "serbest (dogru)");
}

void loop() {
  bool pressed = (digitalRead(BUTTON_PIN) == LOW);  // pull-up: basili = LOW

  // Basma ani
  if (pressed && !lastPressed) {
    downAt = millis();
    Serial.println(">> BASILDI");
  }

  // Birakma ani
  if (!pressed && lastPressed) {
    unsigned long held = millis() - downAt;
    Serial.print(">> BIRAKILDI  (sure: ");
    Serial.print(held);
    Serial.println(" ms)");

    if (held >= 3000) {
      Serial.println("   --> UZUN BASIS algilandi (fabrika ayari islevi)");
    } else {
      unsigned long now = millis();
      if (now - lastShort < 500) shortCount++; else shortCount = 1;
      lastShort = now;
      if (shortCount >= 2) {
        Serial.println("   --> CIFT BASIS algilandi (stok bildirimi islevi)");
        shortCount = 0;
      } else {
        Serial.println("   --> KISA BASIS algilandi ('aldim' onayi islevi)");
      }
    }
  }

  lastPressed = pressed;
  delay(10);
}
