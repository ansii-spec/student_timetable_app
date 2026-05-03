import 'package:flutter/material.dart';

import 'exam_page.dart';
import 'locations_page.dart';
import 'settings_page.dart';
import 'timetable_page.dart';

class TimetableHomePage extends StatefulWidget {
  const TimetableHomePage({
    super.key,
    required this.userEmail,
    required this.userName,
    required this.photoUrl,
    required this.rollNumber,
    required this.onLogout,
  });

  final String userEmail;
  final String userName;
  final String? photoUrl;
  final String rollNumber;
  final VoidCallback onLogout;

  @override
  State<TimetableHomePage> createState() => _TimetableHomePageState();
}

class _TimetableHomePageState extends State<TimetableHomePage> {
  int _selectedIndex = 0;

  String _titleForIndex(int index) {
    switch (index) {
      case 0:
        return 'Home';
      case 1:
        return 'Timetable';
      case 2:
        return 'Exam';
      case 3:
        return 'Locations';
      case 4:
        return 'Settings';
      default:
        return 'Student Timetable';
    }
  }

  Widget _buildHomeTab(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              children: <Widget>[
                CircleAvatar(
                  radius: 42,
                  backgroundImage: widget.photoUrl != null
                      ? NetworkImage(widget.photoUrl!)
                      : null,
                  child: widget.photoUrl == null
                      ? const Icon(Icons.person, size: 42)
                      : null,
                ),
                const SizedBox(height: 14),
                Text(
                  widget.userName,
                  style: Theme.of(context).textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 6),
                Text(
                  widget.userEmail,
                  style: Theme.of(context).textTheme.bodyMedium,
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 18),
                _ProfileField(
                  label: 'Roll Number',
                  value: widget.rollNumber,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<Widget> pages = <Widget>[
      _buildHomeTab(context),
      const TimetablePage(),
      const ExamPage(),
      const LocationsPage(),
      SettingsPage(onLogout: widget.onLogout),
    ];

    return Scaffold(
      appBar: AppBar(
        title: Text(_titleForIndex(_selectedIndex)),
        actions: <Widget>[
          IconButton(
            tooltip: 'Logout',
            onPressed: widget.onLogout,
            icon: const Icon(Icons.logout),
          ),
        ],
      ),
      body: IndexedStack(
        index: _selectedIndex,
        children: pages,
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _selectedIndex,
        onDestinationSelected: (int index) {
          setState(() {
            _selectedIndex = index;
          });
        },
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.home_outlined),
            selectedIcon: Icon(Icons.home),
            label: 'Home',
          ),
          NavigationDestination(
            icon: Icon(Icons.calendar_view_week_outlined),
            selectedIcon: Icon(Icons.calendar_view_week),
            label: 'Timetable',
          ),
          NavigationDestination(
            icon: Icon(Icons.event_note_outlined),
            selectedIcon: Icon(Icons.event_note),
            label: 'Exam',
          ),
          NavigationDestination(
            icon: Icon(Icons.location_on_outlined),
            selectedIcon: Icon(Icons.location_on),
            label: 'Locations',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

class _ProfileField extends StatelessWidget {
  const _ProfileField({
    required this.label,
    required this.value,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Expanded(
          flex: 2,
          child: Text(
            label,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ),
        const Text(': '),
        Expanded(
          flex: 3,
          child: Text(
            value,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
      ],
    );
  }
}
