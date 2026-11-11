#include <Arduino.h>
#include <WiFi.h>
#include <WiFiUdp.h>
#include <Preferences.h>

// LPV1: length LE16 + inverted flag + original camera datagram.
// LPC1 from host: sequence LE16, SSID length, reserved, SSID[32], IPv4[4].
// LPV1 length 8 acknowledgement: LPC1, sequence LE16, status, protocol version.
String cameraSSID = "Soulear-79144";
IPAddress camera(192,168,1,1);
Preferences preferences;
WiFiUDP control, video;
uint16_t seq = 0;
uint32_t lastRequest, lastImage, lastInfo;
bool connected, inverted;
unsigned attempts;
uint8_t buffer[2048];
constexpr size_t prefixSize = 7;
uint8_t usbPacket[prefixSize + sizeof(buffer)];
int congestedFrame = -1;
uint8_t serialInput[44];
size_t serialCount = 0;
uint32_t serialLast = 0;
uint8_t controlReply[22];
size_t controlReplySize = 0;

void request(uint16_t cmd, uint16_t port, bool extended = false) {
  uint8_t data[20] = {0xee,0xff,0xee,0xff, uint8_t(seq),uint8_t(seq >> 8),
                      uint8_t(cmd),0,1,0,uint8_t(extended ? 8 : 0),0};
  ++seq;
  data[12] = uint8_t(22789); data[13] = uint8_t(22789 >> 8);
  control.beginPacket(camera, port); control.write(data, extended ? 20 : 12); control.endPacket();
}

void queueReply(const uint8_t *payload, size_t size) {
  memcpy(controlReply, "LPV1", 4);
  controlReply[4] = uint8_t(size); controlReply[5] = 0; controlReply[6] = 0;
  memcpy(controlReply + 7, payload, size); controlReplySize = size + 7;
}

void applyProfile(const uint8_t *data) {
  uint8_t ack[8] = {'L','P','C','1',data[4],data[5],1,1};
  const uint8_t length = data[6];
  if (length >= 1 && length <= 32 && data[7] == 0 &&
      memchr(data + 8, 0, length) == nullptr && data[40] > 0 && data[40] < 224 && data[40] != 127) {
    char ssid[33] = {}; memcpy(ssid, data + 8, length);
    IPAddress address(data[40],data[41],data[42],data[43]);
    if (cameraSSID != ssid || camera != address) {
      cameraSSID = ssid; camera = address;
      preferences.putString("ssid", cameraSSID);
      preferences.putString("ip", camera.toString());
      control.stop(); video.stop(); connected = false;
      WiFi.disconnect(); WiFi.begin(cameraSSID.c_str());
    }
    ack[6] = 0;
  }
  queueReply(ack, sizeof(ack));
}

// Bounded, nonblocking parser, also active when the camera is switched off.
void readHost() {
  if (serialCount && millis() - serialLast > 500) serialCount = 0;
  for (unsigned budget = 0; budget < 128 && Serial.available(); ++budget) {
    serialLast = millis();
    serialInput[serialCount++] = uint8_t(Serial.read());
    while (serialCount) {
      const bool config = serialInput[0] == 'L';
      const uint8_t magicConfig[4] = {'L','P','C','1'};
      const uint8_t magicLamp[4] = {0xee,0xff,0xee,0xff};
      const uint8_t *magic = config ? magicConfig : magicLamp;
      bool prefix = true;
      for (size_t i = 0; i < min(serialCount, size_t(4)); ++i) if (serialInput[i] != magic[i]) prefix = false;
      if (!prefix) { memmove(serialInput, serialInput + 1, --serialCount); continue; }
      const size_t required = config ? 44 : 15;
      if (serialCount < required) break;
      if (config) applyProfile(serialInput);
      else if (connected && serialInput[6]==10 && serialInput[7]==0 && serialInput[8]==1 &&
               serialInput[9]==0 && serialInput[10]==3 && serialInput[11]==0 &&
               (serialInput[12]==0x01 || serialInput[12]==0x11) && serialInput[13]<=1) {
        control.beginPacket(camera, 10005); control.write(serialInput, 15); control.endPacket();
      }
      serialCount = 0;
    }
  }
}

void setup() {
  Serial.setTxBufferSize(8192); Serial.begin(115200);
  preferences.begin("mrlinse", false);
  String savedSSID = preferences.getString("ssid", cameraSSID);
  IPAddress savedIP;
  if (savedSSID.length() >= 1 && savedSSID.length() <= 32 &&
      savedIP.fromString(preferences.getString("ip", "192.168.1.1"))) {
    cameraSSID = savedSSID; camera = savedIP;
  }
  WiFi.mode(WIFI_STA); WiFi.setSleep(false); WiFi.setAutoReconnect(true);
  WiFi.begin(cameraSSID.c_str());
}

void loop() {
  readHost();
  if (controlReplySize && Serial && Serial.availableForWrite() >= int(controlReplySize)) {
    Serial.write(controlReply, controlReplySize); controlReplySize = 0;
  }
  if (WiFi.status() != WL_CONNECTED) {
    if (connected) { control.stop(); video.stop(); connected = false; }
    static uint32_t retry = millis();
    if (millis() - retry > 5000) { retry = millis(); WiFi.reconnect(); }
    delay(1); return;
  }
  if (!connected) {
    if (!video.begin(22789) || !control.begin(40001)) { control.stop(); video.stop(); delay(20); return; }
    connected = true; inverted = false; attempts = 0; congestedFrame = -1;
    lastInfo = millis() - 6000; lastImage = millis() - 2000; lastRequest = lastImage;
  }
  if (millis() - lastInfo > 5000) { lastInfo = millis(); request(1, 10005); }
  if (millis() - lastImage > 1500 && millis() - lastRequest > 1500) {
    lastRequest = millis(); request(4, 10006, attempts++ % 2 != 0);
  }
  if (control.parsePacket()) {
    int n = control.read(buffer, sizeof(buffer));
    if (control.remoteIP() == camera && n >= 15 && buffer[0]==0xee && buffer[6]==10 && buffer[7]==0) queueReply(buffer, 15);
    if (control.remoteIP() == camera && n >= 77 && buffer[0]==0xee && buffer[6]==1 && buffer[9]==0) {
      char product[33] = {}; memcpy(product, buffer + 45, 32);
      inverted = strstr(product,"FBPRO") || strstr(product,"R1");
    }
  }
  int size = video.parsePacket();
  if (size) {
    uint8_t *payload = usbPacket + prefixSize;
    int n = video.read(payload, sizeof(buffer));
    if (video.remoteIP() != camera || n != size || n <= 16 || (payload[0] != 1 && payload[0] != 6)) return;
    lastImage = millis();
    const int frame = payload[2];
    if (congestedFrame == frame) return;
    congestedFrame = -1;
    const size_t recordSize = prefixSize + n;
    if (!Serial || controlReplySize || Serial.availableForWrite() < int(recordSize)) { congestedFrame = frame; return; }
    memcpy(usbPacket, "LPV1", 4);
    usbPacket[4] = uint8_t(n); usbPacket[5] = uint8_t(n >> 8); usbPacket[6] = uint8_t(inverted);
    if (Serial.write(usbPacket, recordSize) != recordSize) congestedFrame = frame;
  } else delay(1);
}
