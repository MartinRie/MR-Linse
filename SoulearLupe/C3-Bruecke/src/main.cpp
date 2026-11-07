#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>

// Mac receives each original video datagram as LPV1 | uint16 LE length |
// uint8 mountInverted | payload. JPEG and sensor samples stay together.
constexpr char cameraSSID[] = "Soulear-79144";
WiFiUDP control, video;
IPAddress camera;
uint16_t seq = 0;
uint32_t lastRequest, lastImage, lastInfo;
bool connected, inverted;
unsigned attempts;
uint8_t buffer[2048];
// Keep LPV1 framing compatible with earlier Lupe releases.
constexpr size_t prefixSize = 7;
uint8_t usbPacket[prefixSize + sizeof(buffer)];
int congestedFrame = -1;

void request(uint16_t cmd, uint16_t port, bool extended = false) {
  uint8_t data[20] = {0xee,0xff,0xee,0xff, uint8_t(seq),uint8_t(seq >> 8),
                      uint8_t(cmd),0,1,0,uint8_t(extended ? 8 : 0),0};
  ++seq;
  data[12] = uint8_t(22789); data[13] = uint8_t(22789 >> 8);
  control.beginPacket(camera, port);
  control.write(data, extended ? 20 : 12);
  control.endPacket();
}

void setup() {
  Serial.setTxBufferSize(8192);
  Serial.begin(115200);
  WiFi.mode(WIFI_STA);
  WiFi.setSleep(false);
  WiFi.setAutoReconnect(true);
  WiFi.begin(cameraSSID);
}

void loop() {
  if (WiFi.status() != WL_CONNECTED) {
    if (connected) { control.stop(); video.stop(); connected = false; }
    static uint32_t retry = millis();
    if (millis() - retry > 10000) { retry = millis(); WiFi.reconnect(); }
    delay(10);
    return;
  }
  if (!connected) {
    camera = WiFi.gatewayIP();
    if (!video.begin(22789) || !control.begin(40001)) {
      control.stop(); video.stop(); delay(200); return;
    }
    connected = true; inverted = false; attempts = 0; congestedFrame = -1;
    lastInfo = millis() - 6000; lastImage = millis() - 2000; lastRequest = lastImage;
  }
  if (millis() - lastInfo > 5000) {
    lastInfo = millis(); request(1, 10005);
  }
  if (millis() - lastImage > 1500 && millis() - lastRequest > 1500) {
    lastRequest = millis(); request(4, 10006, attempts++ % 2 != 0);
  }
  // Only accept ring-light control requests on the Mac-to-bridge channel.
  while (Serial.available() && Serial.peek() != 0xee) Serial.read();
  if (Serial.available() >= 15) {
    uint8_t cmd[15];
    Serial.readBytes(cmd, sizeof(cmd));
    if (cmd[1]==0xff && cmd[2]==0xee && cmd[3]==0xff && cmd[6]==10 && cmd[7]==0 &&
        cmd[8]==1 && cmd[9]==0 && cmd[10]==3 && cmd[11]==0 && cmd[12]==0x11 && cmd[13]<=1) {
      control.beginPacket(camera, 10005);
      control.write(cmd, sizeof(cmd));
      control.endPacket();
    }
  }
  if (control.parsePacket()) {
    int n = control.read(buffer, sizeof(buffer));
    if (control.remoteIP() == camera && n >= 15 && buffer[6]==10 && buffer[7]==0) {
      uint8_t reply[22] = {'L','P','V','1',15,0,0};
      memcpy(reply+7, buffer, 15);
      Serial.write(reply, sizeof(reply));
    }
    if (control.remoteIP() == camera && n >= 77 && buffer[0]==0xee && buffer[6]==1 && buffer[9]==0) {
      char product[33] = {}; memcpy(product, buffer + 45, 32);
      inverted = strstr(product,"FBPRO") || strstr(product,"R1");
    }
  }
  int size = video.parsePacket();
  if (size) {
    uint8_t *payload = usbPacket + prefixSize;
    int n = video.read(payload, sizeof(buffer));
    if (video.remoteIP() != camera || n != size || n <= 16 ||
        (payload[0] != 1 && payload[0] != 6)) return;
    lastImage = millis();
    const int frame = payload[2];
    if (congestedFrame == frame) return;
    congestedFrame = -1;
    const size_t recordSize = prefixSize + n;
    // A slow or closed USB reader must never stop us draining the camera socket.
    if (!Serial || Serial.availableForWrite() < int(recordSize)) {
      congestedFrame = frame;
      return;
    }
    memcpy(usbPacket, "LPV1", 4);
    usbPacket[4] = uint8_t(n);
    usbPacket[5] = uint8_t(n >> 8);
    usbPacket[6] = uint8_t(inverted);
    if (Serial.write(usbPacket, recordSize) != recordSize) congestedFrame = frame;
  } else delay(1);
}
