import 'package:flutter/material.dart';

/// App-notification relay config (ANCS-style push to the watch).
class NotificationsScreen extends StatelessWidget {
  const NotificationsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Alerts')),
      body: ListView(
        children: const [
          SwitchListTile(
            value: false,
            onChanged: null,
            secondary: Icon(Icons.call),
            title: Text('Incoming calls'),
          ),
          SwitchListTile(
            value: false,
            onChanged: null,
            secondary: Icon(Icons.sms),
            title: Text('Messages'),
          ),
          SwitchListTile(
            value: false,
            onChanged: null,
            secondary: Icon(Icons.apps),
            title: Text('App notifications'),
          ),
        ],
      ),
    );
  }
}
