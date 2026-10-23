# Lyrics Overlay

macOS 메뉴바 가사 앱. 지금 재생 중인 곡의 싱크 가사를 메뉴바, 노래방 패널, 전체 가사 창, 노치 아래에 보여준다.

![icon](Resources/AppIcon-preview.png)

## 기능

| 화면 | 내용 |
|---|---|
| 메뉴바 | 현재 가사(길이 조절). 클릭하면 앨범아트·재생 컨트롤·딜레이·플레이어 선택 창 |
| 노래방 패널 | 현재 줄이 왼쪽→오른쪽으로 채워지는 플로팅 패널. 앨범색 배경, 모든 Space와 전체화면 위에 표시 |
| 전체 가사 창 | 앨범색 메시 그라데이션 배경, 줄을 클릭하면 그 위치로 이동, 전체화면 지원 |
| 노치 | 메뉴바 아이콘이 노치에 가려지면 노치 아래로 가사를 표시 (설정: 끔/자동/항상) |
| 설정 | 일반·노래방·싱크·정보 |

지원 플레이어:

| 플레이어 | 읽는 방법 |
|---|---|
| Music.app, Spotify | AppleScript + 시스템 알림으로 곡 변경 즉시 감지 |
| YouTube Music 웹 (Safari/Chrome/Brave/Edge/Arc) | 탭에서 JavaScript 실행 |
| YT Music.app 등 기타 앱 ("Other Apps") | 시스템 Now Playing (MediaRemote) |
| 로컬 파일 (⌘O) | 직접 재생, 같은 이름의 `.lrc` 사용 |

가사는 LRCLIB → NetEase 순으로 찾는다. 곡 길이로 결과를 검증하고, 찾은 가사는 디스크에 캐시한다(`~/Library/Caches/com.nopgae.lyrics-overlay`).

## 요구 사항

- macOS 14 이상 (전체 가사 창의 움직이는 배경은 macOS 15 이상)
- Xcode 16 이상 (Swift 5.9 toolchain)

## 빌드

```bash
scripts/build.sh               # build/Lyrics Overlay.app (release)
scripts/dmg.sh                 # build/Lyrics-Overlay-<버전>.dmg (Applications로 드래그해 설치)
scripts/run.sh                 # debug 빌드 후 실행 + 로그
swift test                     # LyricsCore 단위 테스트 (LIVE=1 이면 실제 LRCLIB 호출 포함)
scripts/snapshot.sh OUT        # 데모 데이터로 각 화면 PNG 캡처 (화면 기록 권한 필요)
swift scripts/make_icon.swift  # 앱 아이콘 재생성
```

설치: `cp -R "build/Lyrics Overlay.app" /Applications/`

서명 없이(ad-hoc) 빌드하면 다시 빌드할 때마다 macOS가 자동화(Apple Events) 권한을 다시 묻는다.
`SIGN_IDENTITY="..." scripts/build.sh`처럼 고정 인증서를 쓰면 권한이 유지된다.

YouTube Music 웹(Chromium 계열)은 브라우저 메뉴 View → Developer → **Allow JavaScript from Apple Events**를 켜야 한다.
켜지 않아도 "Other Apps"(시스템 Now Playing)로 대부분 잡힌다.

## 구조

- `Sources/LyricsCore`: LRC 파싱, 싱크, 가사 검색/캐시. AppKit이 없어서 단위 테스트 대상
- `Sources/LyricsOverlay/Players`: 플레이어 연동. AppleScript는 직렬 큐 하나에서만 실행
- `Sources/NowPlayingHelper`: 시스템 Now Playing을 읽는 라이브러리. macOS 15.4부터 MediaRemote가
  Apple 서명 프로세스에만 응답하므로 `/usr/bin/perl` 안에서 실행되고 JSON 줄로 결과를 보낸다
- `Sources/LyricsOverlay/LyricsModel.swift`: 상태, 폴링/알림, 다음 줄까지 대기하는 타이머
- `Sources/LyricsOverlay/Views`, `*Panel.swift`, `*Window.swift`: 화면
- `docs/LYRIC_FEVER_NOTES.md`: Lyric Fever 소스 분석 노트

## 이전 버전

첫 버전은 Python(PyObjC)으로 만들었다. 마지막 Python 버전은 `python-v0.5` 태그에 남아 있다.

UI 레이아웃은 [Lyric Fever](https://github.com/aviwad/LyricFever) (MIT)를 참고했다.
