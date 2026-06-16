/* ===========================================================================
 *  DFPlayer TEST v3 - DOSYA + HATA KODU TANISI
 * ---------------------------------------------------------------------------
 *  begin OK ama ses yok. Sorun KART/DOSYA mi yoksa HOPARLOR mu?
 *  Bu test: kart durumunu + dosya sayisini okur, calar, ve DFPlayer'in
 *  donen HATA KODLARINI Turkce aciklamayla yazar.
 *
 *  Baglanti ayni:
 *    VCC->5V, GND->ortak, ESP GPIO17->DF RX, DF TX->ESP GPIO18,
 *    Hoparlor -> SPK_1 / SPK_2
 * =========================================================================== */

#include <DFRobotDFPlayerMini.h>

#define DF_TX 17
#define DF_RX 18

HardwareSerial dfSerial(1);
DFRobotDFPlayerMini df;

void printDetail(uint8_t type, int value) {
  switch (type) {
    case DFPlayerError:
      Serial.print("HATA KODU: ");
      switch (value) {
        case Busy:        Serial.println("Busy - KART BULUNAMADI / takili degil!"); break;
        case Sleeping:    Serial.println("Sleeping"); break;
        case SerialWrongStack: Serial.println("Serial yanlis veri"); break;
        case CheckSumNotMatch: Serial.println("Checksum uymadi (gurultu/baglanti)"); break;
        case FileIndexOut:Serial.println("Dosya index araligi disinda - O NUMARALI DOSYA YOK"); break;
        case FileMismatch:Serial.println("DOSYA BULUNAMADI - kartta 0001.mp3 yok ya da gecersiz"); break;
        case Advertise:   Serial.println("Advertise hatasi"); break;
        default:          Serial.print("bilinmeyen "); Serial.println(value); break;
      }
      break;
    case DFPlayerCardInserted: Serial.println("OLAY: Kart takildi"); break;
    case DFPlayerCardRemoved:  Serial.println("OLAY: Kart cikarildi"); break;
    case DFPlayerPlayFinished: Serial.print("OLAY: Parca bitti #"); Serial.println(value); break;
    default: break;
  }
}

void setup() {
  Serial.begin(115200);
  delay(1000);
  Serial.println("\n=== DFPlayer TEST v3 (dosya/hata tanisi) ===");

  dfSerial.begin(9600, SERIAL_8N1, DF_RX, DF_TX);
  delay(2500);

  if (!df.begin(dfSerial, false, false)) Serial.println("begin false (klon) - devam");
  else Serial.println("begin OK");
  delay(500);

  int state = df.readState();
  Serial.print("readState()      = "); Serial.println(state);

  int files = df.readFileCounts();
  Serial.print("readFileCounts() = "); Serial.println(files);
  if (files <= 0)
    Serial.println("  -> KART/DOSYA SORUNU: kart okunmuyor ya da calinabilir dosya yok.");
  else
    Serial.println("  -> Kart ve dosya GORULUYOR. Ses yoksa sorun HOPARLOR/dosya formatinda.");

  df.volume(30);   // MAX
  delay(300);
  Serial.print("readVolume()     = "); Serial.println(df.readVolume());

  Serial.println(">>> play(1) ...");
  df.play(1);
  delay(2500);

  Serial.println(">>> playMp3Folder(1) (/MP3/0001.mp3 icin) ...");
  df.playMp3Folder(1);
}

void loop() {
  if (df.available()) printDetail(df.readType(), df.read());
  delay(60);
}
