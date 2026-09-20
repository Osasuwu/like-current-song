import 'package:flutter/material.dart';

class AppDrawer extends StatelessWidget {
  const AppDrawer({super.key});

  @override
  Widget build(BuildContext context) {
    return Drawer(
      child: ListView(
        padding: EdgeInsets.zero,
        children: <Widget>[
          const DrawerHeader(
            child: Text('Like Current Song', style: TextStyle(fontSize: 22)),
          ),
          _item(context, 'Trigger configuration', '/trigger-config'),
          _item(context, 'Connected services', '/connected-services'),
          _item(context, 'Battery optimization status', '/battery'),
          _item(context, 'Logs / debug', '/logs'),
          _item(context, 'Permissions', '/permissions'),
          _item(context, 'About', '/about'),
        ],
      ),
    );
  }

  Widget _item(BuildContext context, String title, String route) {
    return ListTile(
      title: Text(title),
      onTap: () {
        Navigator.of(context).pop();
        Navigator.of(context).pushNamed(route);
      },
    );
  }
}
