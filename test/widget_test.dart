import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lead_management_app/screens/login_screen.dart';
import 'package:lead_management_app/main.dart';

void main() {
  testWidgets('shows lead API reception instructions', (tester) async {
    await tester.pumpWidget(const LeadManagementApp());

    expect(find.text('Lead API reception'), findsOneWidget);
    expect(find.text('Endpoint'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('X-Lead-Timestamp'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('X-Lead-Timestamp'), findsOneWidget);
    expect(find.text('X-Lead-Signature'), findsOneWidget);

    await tester.scrollUntilVisible(
      find.text('Duplicate handling'),
      400,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.text('Duplicate handling'), findsOneWidget);
  });

  testWidgets('shows dashboard sign-in and account creation options', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(home: LoginScreen()),
    );

    expect(find.text('Sign in to Lead Management'), findsOneWidget);
    expect(find.text('Continue with Google'), findsOneWidget);
    expect(find.text('Email'), findsOneWidget);
    expect(find.text('Password'), findsOneWidget);
    expect(find.text('New here? Create an account'), findsOneWidget);
  });
}
