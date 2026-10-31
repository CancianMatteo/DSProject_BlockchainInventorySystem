class ApiResponse<T> {
  final bool ok;
  final T? data;
  final String? errorMessage;

  ApiResponse({required this.ok, this.data, this.errorMessage});

  factory ApiResponse.fromJson(
    Map<String, dynamic> json,
    T Function(dynamic) fromJsonT,
  ) {
    final bool isOk = json['ok'] ?? false;
    final dynamic rawData = json.containsKey('data') ? json['data'] : json;

    T? parsedData;
    if (isOk) {
      parsedData = fromJsonT(rawData);
    }

    return ApiResponse<T>(
      ok: isOk,
      data: parsedData,
      errorMessage: isOk
          ? null
          : json['error']?['message'] ?? 'Unknown error',
    );
  }

  factory ApiResponse.error(String message) {
    return ApiResponse<T>(ok: false, errorMessage: message);
  }
}
