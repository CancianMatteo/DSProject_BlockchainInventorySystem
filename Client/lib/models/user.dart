class User {
  final String name;
  final String surname;
  final String email;
  final String role;

  User({required this.name, required this.surname, required this.email, required this.role});

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      name: json['name'],
      surname: json['surname'],
      email: json['email'],
      role: json['role'],
    );
  }
}
