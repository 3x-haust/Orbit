<div align="center">

<img src="docs/assets/icon.png" width="128" alt="Orbit 아이콘" />

# Orbit

**맥의 모든 유틸리티 앱을 한 번에**

[![Release](https://img.shields.io/github/v/release/3x-haust/Orbit?style=flat-square&color=ff6b35&label=release)](https://github.com/3x-haust/Orbit/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B-000000?style=flat-square&logo=apple&logoColor=white)](#요구-사항)
[![Swift](https://img.shields.io/badge/Swift-6-F05138?style=flat-square&logo=swift&logoColor=white)](https://swift.org)
[![License](https://img.shields.io/badge/license-MIT-white?style=flat-square)](LICENSE)

[**다운로드**](https://github.com/3x-haust/Orbit/releases/latest) · [기능](#기능) · [직접 빌드](#직접-빌드)

[English](README.md) · **한국어**

<br/>

<img src="docs/assets/ko/hero.png" alt="Orbit" width="100%" />

<br/><br/>

<a href="https://github.com/3x-haust/Orbit/raw/main/docs/promo/orbit-promo-16x9-ko.mp4">
  <img src="docs/promo/orbit-promo-ko.gif" alt="Orbit 소개 영상" width="100%" />
</a>

<sub><a href="https://github.com/3x-haust/Orbit/raw/main/docs/promo/orbit-promo-16x9-ko.mp4">▶︎ 소리와 함께 보기</a></sub>

</div>

<br/>

메뉴 막대를 가득 채운 앱 여러 개 대신, 빠르고 가벼운 네이티브 앱 하나. 캡처, 클립보드 기록, 런처, 창 정리, 번역, 맞춤법, 메뉴 막대 정리, 잠자기 방지, 앱별 음량, 시스템 모니터까지 — 포인터 주변에 열리는 **링** 하나로 다 꺼내 써요.

검정과 흰색, 그리고 오렌지 한 방울. SwiftUI + AppKit 네이티브, Electron 없음, 계정도 서버도 분석도 없어요.

## 기능

<table>
<tr>
<td width="50%"><img src="docs/assets/ko/tile-capture.png" alt="캡처" /></td>
<td width="50%"><img src="docs/assets/ko/tile-windows.png" alt="창 정리" /></td>
</tr>
<tr>
<td><img src="docs/assets/ko/tile-menubar.png" alt="메뉴 막대" /></td>
<td><img src="docs/assets/ko/tile-translate.png" alt="번역" /></td>
</tr>
<tr>
<td><img src="docs/assets/ko/tile-sound.png" alt="사운드" /></td>
<td><img src="docs/assets/ko/tile-system.png" alt="시스템" /></td>
</tr>
<tr>
<td><img src="docs/assets/ko/tile-awake.png" alt="잠자기 방지" /></td>
<td><img src="docs/assets/ko/tile-displays.png" alt="디스플레이" /></td>
</tr>
</table>

### 기본

| | |
|---|---|
| 🪐 **Orbit 링** | 단축키나 마우스 가운데 버튼을 누르면 포인터 주변에 링이 열려요. 3~12칸, 프리셋, 끌어서 편집. |
| 📸 **캡처** | 영역·창·전체·타이머·스크롤 캡처(빨리 스크롤해도 따라가요). 영역 고를 때 ⇧ 비율 고정, ⌥ 가운데부터, Space 이동, Tab 비율, R 지난 영역, C/S/E/P/T/V/L로 바로 동작 선택. 클릭이 강조되는 화면 녹화. 화살표·글자·블러·픽셀화·스포트라이트·돋보기·자·색 추출 편집기. 화면 글자 인식. |
| 📋 **클립보드** | 글자·이미지·파일·색 기록을 검색하고 한 번 눌러 붙여 넣어요. |
| 🪟 **창 정리** | 반쪽·삼분할·사분할·가운데·최대화를 키보드로. 스테이지 매니저, 독, 여러 모니터를 알아서 피해요. |
| 🌐 **번역** | 아무 앱에서나 ⌘C 두 번. Google, DeepL(내 키), Apple 중에서 고르고 언어는 자동으로 알아내요. |
| ✓ **맞춤법** | 글자를 고르고 ⌥⇧K. 다음·네이버 검사기(동의 후) 또는 기기 안의 Apple Intelligence로 맞춤법과 띄어쓰기를 고치고, 그 자리에서 바로 바꿔요. |
| ✍️ **스니펫** | 줄임말을 치면 전체 문장으로 바뀌어요. |
| 🔐 **비밀번호** | 종단간 암호화 보관함(PBKDF2 + 비밀 키, 항목별 AES-GCM), Touch ID, 보안 점검, 브라우저에서 가져오기. |

### 유틸리티

| | |
|---|---|
| 🔊 **사운드** | 앱별 음량과 EQ, 전체 소리 EQ. |
| 🔳 **노치** | 살아 있는 노치: 앨범 아트와 음악, 일정, 타이머, 충전·에어팟, 음량·밝기 표시, 파일 선반까지 — 마우스를 올리거나 쓸어서 열어요. |
| 🎵 **지금 재생 중** | 노치에서 앨범 아트와 함께 조작하고, 곡이 바뀌면 배너로 알려줘요. 영상이 나오면 음악을 잠시 멈춰요. |
| ⌨️ **입력** | 한/영 자동 전환, 마우스·트랙패드 스크롤 방향 따로, 키보드 청소 잠금. |
| ☕️ **잠자기 방지** | 시간·시각·앱 실행 동안 — 덮개를 닫아도. |
| ✦ **메뉴 막대** | 아이콘을 진짜로 숨기고(« 없음), 필요할 때 하나만 꺼내요. 메뉴 막대 달력도. |
| 🔲 **핫 코너** | 모서리마다 원하는 동작. |
| 🏃 **러너** | 메뉴 막대의 작은 CPU 애니메이션. |
| 🙂 **얼굴로 잠금 해제** | macOS 암호 창을 얼굴로 채워요. |
| 🗂 **선반** | 노치나 화면 가장자리에서 자라나는 파일 놓는 곳. |

### Mac

| | |
|---|---|
| 🧩 **앱** | 모든 앱을 카테고리별 격자로, 검색까지. |
| 📈 **시스템** | CPU·메모리·GPU·디스크·네트워크·배터리·온도·팬. 카드를 누르면 프로세스별로 자세히. |
| 🖥 **디스플레이** | 외장 모니터 밝기·음량(DDC), macOS 같은 표시. |
| 🔋 **배터리** | 충전 한도와 유지 모드. |
| 🧹 **저장 공간** | 무엇이 공간을 차지하는지 보고, 지워도 되는 것만 정리. 앱은 남은 파일까지 삭제. |
| 🗜 **압축** | Zip, 7z 등 — 윈도우에서도 이름이 안 깨져요. 폴더·압축 파일 훑어보기. |

## 설치

1. [최신 릴리즈](https://github.com/3x-haust/Orbit/releases/latest)에서 `Orbit-<버전>.dmg`(또는 `.zip`)를 받아요.
2. 열어서 **Orbit**을 **응용 프로그램**으로 끌어다 놓아요.
3. Orbit을 켜면 메뉴 막대에 들어가고, 설정 페이지가 필요한 권한을 안내해요.

Orbit은 GitHub 릴리즈에서 스스로 업데이트해요. **일반 › 업데이트**에서 자동 확인·자동 설치를 켜고 끌 수 있어요.

> [!NOTE]
> 릴리즈는 서명돼 있지만 공증은 받지 않았어요. "개발자를 확인할 수 없다"고 나오면 Orbit.app을 우클릭 › **열기**, 또는 **시스템 설정 › 개인정보 보호 및 보안**에서 허용해 주세요.

### 권한

| 권한 | 쓰는 곳 |
|---|---|
| 손쉬운 사용 | 창 정리, 단축키, 링, 스니펫, 메뉴 막대 |
| 화면 기록 | 캡처, 녹화, 색 추출, 메뉴 막대 미리보기 |
| 전체 디스크 접근 | 메뉴 막대 아이콘 진짜로 숨기기, 저장 공간 분석 |
| 카메라 | 얼굴로 잠금 해제(기기 안에서만) |
| 캘린더 | 메뉴 막대 달력과 노치의 일정 |
| 블루투스 | 노치의 에어팟·기기 연결 알림 |

모든 데이터는 이 Mac에만 있어요. 계정도 서버도 분석도 없고, 네트워크는 고른 번역·맞춤법 엔진과 업데이트 확인에만 써요.

## 요구 사항

- macOS 15 Sequoia 이상 (Liquid Glass, Apple 번역, Apple Intelligence 맞춤법은 macOS 26 이상)
- Apple silicon (M 시리즈 맥북에서 테스트)

## 직접 빌드

```bash
brew install xcodegen
git clone https://github.com/3x-haust/Orbit.git
cd Orbit
xcodegen generate
python3 tools/i18n.py          # 한국어 문자열 합치기
open Orbit.xcodeproj
```

빌드 전에 `project.yml`의 `DEVELOPMENT_TEAM`, `CODE_SIGN_IDENTITY`를 내 서명으로 바꿔 주세요. 팬·배터리 도우미와 훑어보기 확장은 실제 서명이 있어야 해요.

### 프로젝트 구조

```
Orbit/
├── App/            # 메인 창, 페이지, 설정 검색
├── Core/           # 단축키, 이벤트 탭, 잠자기 방지, 업데이트
├── Design/         # 색, 컴포넌트
└── Modules/        # 기능마다 폴더 하나 (Capture, Clipboard, MenuBar, …)
FanHelper/          # SMC용 도우미 (팬, 충전)
OrbitQuickLook/     # 폴더·압축 파일 훑어보기 확장
NowPlayingAdapter/  # 미디어 정보 브리지
tools/              # 번역 합치기, 설정 색인, 아이콘 렌더링
```

## 기여하기

이슈와 풀 리퀘스트 환영해요. 스타일만 지켜 주세요: 네이티브 API, 무거운 의존성 없이, 검정·흰색에 오렌지는 아껴서, 모든 문자열은 영어로 쓰고 한국어 번역은 `tools/i18n/`에.

## 라이선스

[MIT](LICENSE) © 3x-haust
