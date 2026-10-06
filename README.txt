C.P Phone GPS Edge Driver v1.0.7

변경 사항
- NAS PhoneGPS-Logger /api/phones 조회
- 화면 표시 개수 1~4 동적 프로필 유지
- 주소 표시: 도로명 우선, 없으면 지번
- ESL 화면 갱신 주기 설정 추가: 최소 30초, 기본 60초
- 화면 표시 개수/ESL 갱신 주기 변경 시 NAS /api/settings 로 저장
- Edge와 ESP는 직접 연결하지 않음

NAS 설정 동기화 JSON
{
  "display_count": 2,
  "esl_refresh_seconds": 60
}

주의
- PhoneGPS-Logger에 GET/POST /api/settings API가 있어야 설정 저장이 완료됩니다.


[v1.0.9]
- PhoneGPS NAS/API poll failures no longer force SmartThings device offline/online state.
- Poll failure/recovery is still reported to C.P System Monitor and summary.
- Existing GPS/location/settings behavior unchanged.
