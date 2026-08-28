// $Id: ControlApplication.hpp 13554 2026-03-02 20:33:29Z jussi $

/*

  HQPlayer control application.
  Copyright (C) 2015-2026 Jussi Laako.

  Permission is hereby granted, free of charge, to any person obtaining a copy
  of this software and associated documentation files (the "Software"), to deal
  in the Software without restriction, including without limitation the rights
  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
  copies of the Software, and to permit persons to whom the Software is
  furnished to do so, subject to the following conditions:

  The above copyright notice and this permission notice shall be included in
  all copies or substantial portions of the Software.

  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
  THE SOFTWARE.

*/


#ifndef CONTROLAPPLICATION_HPP
#define CONTROLAPPLICATION_HPP

#include <QObject>
#include <QByteArray>
#include <QHash>
#include <QString>
#include <QStringList>
#include <QVariant>

#include "ControlInterface.hpp"


class clControlApplication : public QObject
{
        Q_OBJECT

        clControlInterface *ci;
        QStringList args;
        bool statusSub;

    public:
        clControlApplication (QObject * = 0);
        virtual ~clControlApplication ();
        void start (const QString &, const QStringList &);

    protected slots:
        void onHostDiscovered (QString, QString, QString);
        void onConnected ();
        void onError (QString);
        void onResponse (QString, QString);
        void onEndOfResponse ();
        void onInfo (QString, QString, QString, QString, QString);
        void onLicense (bool, QString, QString);
        void onLibraryHash (QString);
        void onLibraryDirectory (QString, QString,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString, QString, QString,
            QString, QString,
            QString, QString, bool,
            QVariantHash);
        void onLibraryFile (QString, QString,
            QString, QString, QString, QString,
            QString, QString,
            double, unsigned,
            QString, bool,
            QVariantHash);
        void onLibraryPicture (QString, QByteArray);
        void onPlaylistItem (unsigned,
            unsigned, unsigned, unsigned, unsigned,
            QString, QString,
            QString, QString, QString, QString, QString,
            double, QString, QByteArray);
        void onPlaylistBegin (QString);
        void onPlaylistEntry (
            QString, QString, QString, QString,
            double, qulonglong,
            bool, bool, unsigned, unsigned, unsigned, unsigned,
            double, double,
            QString, QString, QString, QString,
            QString, QString, QString, QString);
        void onPlaylists (QStringList);
        void onMatrixProfileItem (QString);
        void onMatrixProfile (QString);
        void onModesItem (unsigned, QString, int);
        void onFiltersItem (unsigned, QString, int, unsigned, QString);
        void onShapersItem (unsigned, QString, int);
        void onRatesItem (unsigned, unsigned);
        void onJunkFiltersItem (unsigned, QString, int);
        void onVolumeRangeResponse (double, double, bool, bool);
        void onDisplayResponse (int);
        void onTransportResponse (int, QString);
        void onStateResponse (int,
            int, int, int, int, int, int,
            double,
            unsigned, unsigned,
            bool, bool, int, bool, bool, int,
            QString);
        void onStatusResponse (int,
            unsigned, QString, int, int,
            double, unsigned,
            unsigned, unsigned, unsigned,
            bool,
            double, double,
            int, int,
            int, int,
            int, int,
            long,
            unsigned);
        void onStatusIO (
            float, float,
            float);
        void onInputsItem (QString);
};

#endif  // CONTROLAPPLICATION_HPP

