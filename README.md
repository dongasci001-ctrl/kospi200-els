# 코스피200 ELS 모니터

코스피200·코스피·코스닥 지수, ELS 배리어 대비 현황, 시가총액 상위 10종목, 대외 변수, 투자자별 수급을 보여주는 대시보드입니다.

- 페이지: `index.html` (GitHub Pages로 공개)
- 데이터: `data/*.json`, `scripts/fetch-market-data.ps1`이 수집
- 갱신: `.github/workflows/refresh-data.yml`이 평일 08:40~15:40(KST) 매시 40분에 실행. Actions 탭에서 "Run workflow"로 수동 실행도 가능
- ELS 조건(배리어·평가일)은 `index.html`의 `ELS` 상수, 기준일은 스크립트의 `-BaseDate` 기본값에서 수정

출처: 네이버 증권, Yahoo Finance. 내부 모니터링용 자료이며 투자 판단의 근거가 아닙니다.
