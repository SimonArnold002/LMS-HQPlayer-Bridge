// $Id: ControlInterface.cpp 13554 2026-03-02 20:33:29Z jussi $

/*

  HQPlayer Qt-based control interface.
  Copyright (C) 2011-2026 Jussi Laako.

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


#include <memory>
#ifndef _WIN32
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#endif  // _WIN32

#include <QHostAddress>
#include <QMutexLocker>
#include <QNetworkDatagram>

#include <botan/version.h>
#include <botan/types.h>
#include <botan/secmem.h>
#include <botan/data_src.h>
#include <botan/pipe.h>
#include <botan/filters.h>
#include <botan/rng.h>
#include <botan/auto_rng.h>
#include <botan/pubkey.h>
#include <botan/aead.h>
#include <botan/x509_key.h>
#include <botan/x509_obj.h>
#include <botan/pkcs8.h>
#include <botan/ec_group.h>
#include <botan/ecdh.h>


#include "ControlInterface.hpp"


#if BOTAN_VERSION_CODE < BOTAN_VERSION_CODE_FOR(3,0,0)
#define BOTAN_DIR_ENCRYPTION    Botan::Cipher_Dir::ENCRYPTION
#define BOTAN_DIR_DECRYPTION    Botan::Cipher_Dir::DECRYPTION
#define BOTAN_EC_GROUP          Botan::EC_Group("secp256r1")
#else
#define BOTAN_DIR_ENCRYPTION    Botan::Cipher_Dir::Encryption
#define BOTAN_DIR_DECRYPTION    Botan::Cipher_Dir::Decryption
#define BOTAN_EC_GROUP          Botan::EC_Group::from_name("secp256r1")
#endif


static const char *hqplayerPubEd25519 =
"-----BEGIN PUBLIC KEY-----\n\
MCowBQYDK2VwAyEA/4K7uJwC21X9M/uT5pr+Ss3TW18kKzqmzisHTzR/lMs=\n\
-----END PUBLIC KEY-----\n";


class clControlInterfacePrivate
{
    public:
        Botan::AutoSeeded_RNG prng;
        Botan::SymmetricKey sessionKey;
        std::unique_ptr<Botan::ECDH_PrivateKey> kexPrivateKey;
        std::unique_ptr<Botan::PK_Key_Agreement> kex;
        std::unique_ptr<Botan::Private_Key> sigPrivateKey;
        std::unique_ptr<Botan::Public_Key> sigPublicKey;
};


// --- clMeterInterface


clMeterInterface::clMeterInterface (QObject *parent) :
    QObject(parent)
{
    msocket = new QTcpSocket(this);
    connect(msocket,
        SIGNAL(connected()),
        SLOT(onConnected()));
    connect(msocket,
        SIGNAL(disconnected()),
        SLOT(onDisconnected()));
#   if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
    connect(msocket,
        SIGNAL(error(QAbstractSocket::SocketError)),
        SLOT(onError(QAbstractSocket::SocketError)));
#   else
    connect(msocket,
        SIGNAL(errorOccurred(QAbstractSocket::SocketError)),
        SLOT(onError(QAbstractSocket::SocketError)));
#   endif
    connect(msocket,
        SIGNAL(readyRead()),
        SLOT(onReadyRead()));
}


clMeterInterface::~clMeterInterface ()
{
    // make sure we don't get called from socket handler
    if (msocket) delete msocket;
}


void clMeterInterface::setServer (QString hostname, quint16 hostport)
{
    serverHost = hostname;
    serverPort = hostport + 1;
}


bool clMeterInterface::getData (QByteArray &head, QByteArray &data)
{
    QMutexLocker lock(&mutex);

    if (dataQueue.isEmpty())
        return false;

    QPair<QByteArray, QByteArray> dataPair(dataQueue.dequeue());
    head = dataPair.first;
    data = dataPair.second;
    return true;
}


bool clMeterInterface::waitData (QByteArray &head, QByteArray &data,
    unsigned timeout)
{
    QMutexLocker lock(&mutex);
    if (condition.wait(&mutex, timeout))
    {
        if (dataQueue.isEmpty())
            return false;

        QPair<QByteArray, QByteArray> dataPair(dataQueue.dequeue());
        head = dataPair.first;
        data = dataPair.second;
        return true;
    }
    return false;
}


void clMeterInterface::onSetMetering (bool enabled)
{
    if (enabled)
    {
        if (isConnected())
            return;

        msocket->setReadBufferSize(65760);  // 16464, 65536, 65760

        if (serverHost == "localhost")
            msocket->connectToHost(
                QHostAddress(QHostAddress::LocalHost), serverPort);
        else if (serverHost == "localhost6")
            msocket->connectToHost(
                QHostAddress(QHostAddress::LocalHostIPv6), serverPort);
        else
            msocket->connectToHost(serverHost, serverPort);
    }
    else
    {
        msocket->disconnectFromHost();
    }
}


bool clMeterInterface::isConnected ()
{
    return (msocket->state() == QAbstractSocket::ConnectedState);
}


void clMeterInterface::onConnected ()
{
    connected = true;
    qDebug("metering connected");
}


void clMeterInterface::onDisconnected ()
{
    connected = false;
    qDebug("metering disconnected");
}


void clMeterInterface::onError (
    QAbstractSocket::SocketError socketError)
{
    if (socketError != QAbstractSocket::SocketTimeoutError)
        emit error(msocket->errorString());
}


void clMeterInterface::onReadyRead ()
{
    const qint64 sizeHead = sizeof(head_t);
    qint64 sizeData;

    readBuffer.append(msocket->readAll());
    while (readBuffer.size() > sizeHead)
    {
        const head_t *header =
            reinterpret_cast<const head_t *> (readBuffer.constData());
        sizeData = header->channels *
            (sizeof(data_t) +
             header->xformLength * sizeof(float) +
             header->xformLength * sizeof(float));
        if (readBuffer.size() >= (sizeHead + sizeData))
        {
            QMutexLocker lock(&mutex);

            QByteArray meterHead(readBuffer.first(sizeHead));
            readBuffer.remove(0, sizeHead);
            QByteArray meterData(readBuffer.first(sizeData));
            readBuffer.remove(0, sizeData);

            dataQueue.enqueue(qMakePair(meterHead, meterData));

            condition.wakeAll();
            emit meterUpdated();
        }
        else break;
    }
}


// --- clControlInterface


void clControlInterface::completeAuthentication ()
{
    try
    {
        QByteArray kexPeerPublicKey = QByteArray::fromBase64(
            xreader->attributes().value("public_key").toLatin1());
        QByteArray kexSignature = QByteArray::fromBase64(
            xreader->attributes().value("signature").toLatin1());
        Botan::PK_Verifier verifier(*p->sigPublicKey, "SHA-256");
        verifier.update(
            reinterpret_cast<const uint8_t *> (kexPeerPublicKey.data()),
            kexPeerPublicKey.size());
        if (verifier.check_signature(
            reinterpret_cast<const uint8_t *> (kexSignature.data()),
            kexSignature.size()))
        {
            p->sessionKey = p->kex->derive_key(
                32,
                reinterpret_cast<const uint8_t *> (kexPeerPublicKey.data()),
                kexPeerPublicKey.size());
            hasSessionKey = true;

            QVersionNumber version(0);
            QString nonce =
                xreader->attributes().value("nonce").toString();
            QString encodedVers =
                xreader->attributes().value("version").toString();
            if (!nonce.isEmpty() && !encodedVers.isEmpty())
            {
                QByteArray cipherNonce(
                    QByteArray::fromBase64(nonce.toLatin1()));
                Botan::Cipher_Mode_Filter *decryptorFilter =
                    new Botan::Cipher_Mode_Filter(
                        Botan::AEAD_Mode::create_or_throw(
                            "ChaCha20Poly1305",
                            BOTAN_DIR_DECRYPTION));
                decryptorFilter->set_iv(Botan::InitializationVector(
                    reinterpret_cast<uint8_t *> (cipherNonce.data()),
                    cipherNonce.size()));
                decryptorFilter->set_key(Botan::SymmetricKey(
                    p->sessionKey));

                Botan::Pipe decryptorPipe(
                    new Botan::Base64_Decoder,
                    decryptorFilter);
                decryptorPipe.process_msg(encodedVers.toStdString());
                version = QVersionNumber::fromString(QString::fromStdString(
                    decryptorPipe.read_all_as_string()));
            }

            emit authenticated(version);
        }
        else
            emit error(QStringLiteral("signature verification failed"));
    }
    catch (std::exception &x)
    {
        emit error(x.what());
    }
    catch (...)
    {
        emit error(QStringLiteral("authentication failure"));
    }
}


clControlInterface::clControlInterface (QObject *parent) :
    QObject(parent)
{
    p.reset(new clControlInterfacePrivate);

    discoSocket = new QUdpSocket(this);
    discoSocket->setSocketOption(
        QAbstractSocket::MulticastLoopbackOption, 1);
    if (!discoSocket->bind(
        QHostAddress::Any, 0,
        QAbstractSocket::ReuseAddressHint))
        qDebug("binding discovery socket failed!");
    /*qDebug("bound to: %s:%u",
        discoSocket->localAddress().toString().toUtf8().constData(),
        discoSocket->localPort());*/
    connect(discoSocket,
        SIGNAL(readyRead()),
        SLOT(onDiscoReadyRead()));

    csocket = new QTcpSocket(this);
    connect(csocket,
        SIGNAL(connected()),
        SLOT(onConnected()));
    connect(csocket,
        SIGNAL(disconnected()),
        SLOT(onDisconnected()));
#   if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
    connect(csocket,
        SIGNAL(error(QAbstractSocket::SocketError)),
        SLOT(onError(QAbstractSocket::SocketError)));
#   else
    connect(csocket,
        SIGNAL(errorOccurred(QAbstractSocket::SocketError)),
        SLOT(onError(QAbstractSocket::SocketError)));
#   endif
    connect(csocket,
        SIGNAL(readyRead()),
        SLOT(onReadyRead()));

    meterThread = new QThread;
    meterInterface = new clMeterInterface;
    meterInterface->moveToThread(meterThread);
    connect(meterThread,
        SIGNAL(finished()),
        meterInterface,
        SLOT(deleteLater()));
    connect(this,
        SIGNAL(enableMetering(bool)),
        meterInterface,
        SLOT(onSetMetering(bool)));
    meterThread->start();
    
    xreader = 0;
    xwriter = 0;
    hasSessionKey = false;

    pictureSize = 0;
}


clControlInterface::~clControlInterface ()
{
    if (isConnected())
        disconnectFromHost();

    // make sure we don't get called from socket handler
    if (csocket) delete csocket;
    if (xreader) delete xreader;
    if (xwriter) delete xwriter;

    meterThread->quit();
    meterThread->wait();
}


void clControlInterface::discoverHosts (quint16 port)
{
    QByteArray message;
    QXmlStreamWriter xmlRequest(&message);

    xmlRequest.writeStartDocument();
    xmlRequest.writeTextElement(
        QStringLiteral("discover"),
        QStringLiteral("hqplayer"));
    xmlRequest.writeEndDocument();

    discoSocket->writeDatagram(message,
        QHostAddress(QStringLiteral("239.192.0.199")), port);
    discoSocket->writeDatagram(message,
        QHostAddress(QStringLiteral("ff08::c7")), port);
}


void clControlInterface::connectToHost (const QString &hostname, quint16 port)
{
    disconnectFromHost();

    if (hostname == "localhost")
        csocket->connectToHost(QHostAddress(QHostAddress::LocalHost), port);
    else if (hostname == "localhost6")
        csocket->connectToHost(QHostAddress(QHostAddress::LocalHostIPv6), port);
    else
        csocket->connectToHost(hostname, port);
    if (!csocket->waitForConnected(1000))
        return;

    serverHost = hostname;
    serverPort = port;
    meterInterface->setServer(serverHost, serverPort);
}


void clControlInterface::disconnectFromHost ()
{
    hasSessionKey = false;
    if (xreader)
    {
        delete xreader;
        xreader = 0;
    }
    if (xwriter)
    {
        delete xwriter;
        xwriter = 0;
    }
    csocket->disconnectFromHost();
    meterThread->disconnect();
}


bool clControlInterface::isConnected ()
{
    return (csocket->state() == QAbstractSocket::ConnectedState);
}


void clControlInterface::sendKeepAlive ()
{
    csocket->write(" ");
}


void clControlInterface::authenticate (const QString &appId,
    const char *privateKey, const char *passphrase)
{
    if (!xwriter)
        return;

    try
    {
        std::string strPrivateKey(privateKey);
        std::string strPassphrase(passphrase);
        Botan::DataSource_Memory sigKeyMem(strPrivateKey);
#       if BOTAN_VERSION_CODE < BOTAN_VERSION_CODE_FOR(3,0,0)
        p->sigPrivateKey.reset(Botan::PKCS8::load_key(
            sigKeyMem, p->prng, strPassphrase));
#       else
        p->sigPrivateKey = Botan::PKCS8::load_key(
            sigKeyMem, strPassphrase);
#       endif

        Botan::DataSource_Memory pubKeyMem(
            reinterpret_cast<const uint8_t *> (hqplayerPubEd25519),
            strlen(hqplayerPubEd25519) + 1);
#       if BOTAN_VERSION_CODE < BOTAN_VERSION_CODE_FOR(3,0,0)
        p->sigPublicKey.reset(Botan::X509::load_key(pubKeyMem));
#       else
        p->sigPublicKey = Botan::X509::load_key(pubKeyMem);
#       endif

        p->kexPrivateKey.reset(new Botan::ECDH_PrivateKey(
            p->prng,
            BOTAN_EC_GROUP));
        p->kex.reset(new Botan::PK_Key_Agreement(
            *p->kexPrivateKey, p->prng, "HKDF(SHA-256)"));
        std::vector<uint8_t> kexPublicKey(p->kexPrivateKey->public_value());

        Botan::PK_Signer signer(*p->sigPrivateKey, p->prng, "SHA-256");
        signer.update(kexPublicKey);
        std::vector<uint8_t> signature(signer.signature(p->prng));

        xwriter->writeStartDocument();
        xwriter->writeStartElement(QStringLiteral("SessionAuthentication"));
        xwriter->writeAttribute(QStringLiteral("client_id"), appId);
        xwriter->writeAttribute(QStringLiteral("public_key"),
            QByteArray(
                reinterpret_cast<const char *> (kexPublicKey.data()),
                kexPublicKey.size()).toBase64());
        xwriter->writeAttribute(QStringLiteral("signature"),
            QByteArray(
                reinterpret_cast<const char *> (signature.data()),
                signature.size()).toBase64());
        xwriter->writeEndElement();
        xwriter->writeEndDocument();
    }
    catch (std::exception &x)
    {
        emit error(x.what());
    }
    catch (...)
    {
        emit error(QStringLiteral("authentication error"));
    }
}


bool clControlInterface::isAuthenticated ()
{
    return hasSessionKey;
}


void clControlInterface::getInfo ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetInfo"));
    xwriter->writeEndDocument();
}


void clControlInterface::getLicense ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetLicense"));
    xwriter->writeEndDocument();
}


void clControlInterface::reset ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Reset"));
    xwriter->writeEndDocument();
    xwriter->device()->waitForBytesWritten(1000);
}


void clControlInterface::configurationList ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("ConfigurationList"));
    xwriter->writeEndDocument();
}


void clControlInterface::configurationGet ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("ConfigurationGet"));
    xwriter->writeEndDocument();
}


void clControlInterface::configurationLoad (const QString &cfgbase)
{
    if (!xwriter)
        return;

    if (hasSessionKey)
    {
        xwriter->writeStartDocument();
        xwriter->writeStartElement(QStringLiteral("ConfigurationLoad"));
        try
        {
            Botan::Cipher_Mode_Filter *encryptorFilter =
                new Botan::Cipher_Mode_Filter(
                    Botan::AEAD_Mode::create_or_throw(
                        "ChaCha20Poly1305",
                        BOTAN_DIR_ENCRYPTION));
            Botan::InitializationVector encryptorIV(p->prng, 12);
            encryptorFilter->set_iv(encryptorIV);
            encryptorFilter->set_key(p->sessionKey);

            Botan::Pipe encryptorPipe(
                encryptorFilter,
                new Botan::Base64_Encoder);
            encryptorPipe.process_msg(cfgbase.toStdString());
            xwriter->writeAttribute(
                QStringLiteral("value"),
                QString::fromStdString(encryptorPipe.read_all_as_string()));
            xwriter->writeAttribute(
                QStringLiteral("nonce"),
                QByteArray(
                    reinterpret_cast<const char *> (encryptorIV.begin()),
                    encryptorIV.size()).toBase64());
        }
        catch (std::exception &x)
        {
            emit error(x.what());
        }
        catch (...)
        {
            emit error(QStringLiteral("failed to send secure message"));
        }
        xwriter->writeEndElement();
        xwriter->writeEndDocument();
    }
}


void clControlInterface::libraryLoad (const QString &libbase)
{
    if (!xwriter)
        return;

    if (hasSessionKey)
    {
        xwriter->writeStartDocument();
        xwriter->writeStartElement(QStringLiteral("LibraryLoad"));
        try
        {
            Botan::Cipher_Mode_Filter *encryptorFilter =
                new Botan::Cipher_Mode_Filter(
                    Botan::AEAD_Mode::create_or_throw(
                        "ChaCha20Poly1305",
                        BOTAN_DIR_ENCRYPTION));
            Botan::InitializationVector encryptorIV(p->prng, 12);
            encryptorFilter->set_iv(encryptorIV);
            encryptorFilter->set_key(p->sessionKey);

            Botan::Pipe encryptorPipe(
                encryptorFilter,
                new Botan::Base64_Encoder);
            encryptorPipe.process_msg(libbase.toStdString());
            xwriter->writeAttribute(
                QStringLiteral("value"),
                QString::fromStdString(encryptorPipe.read_all_as_string()));
            xwriter->writeAttribute(
                QStringLiteral("nonce"),
                QByteArray(
                    reinterpret_cast<const char *> (encryptorIV.begin()),
                    encryptorIV.size()).toBase64());
        }
        catch (std::exception &x)
        {
            emit error(x.what());
        }
        catch (...)
        {
            emit error(QStringLiteral("failed to send secure message"));
        }
        xwriter->writeEndElement();
        xwriter->writeEndDocument();
    }
}


void clControlInterface::libraryGetHash ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("LibraryGetHash"));
    xwriter->writeEndDocument();
}


void clControlInterface::libraryGet (bool pictures)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryGet"));
    xwriter->writeAttribute(QStringLiteral("pictures"),
        QString::number((int) pictures));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryPictureByPath (const QString &path)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryPicture"));
    xwriter->writeAttribute(QStringLiteral("path"), path);
    //xwriter->writeAttribute(QStringLiteral("base64"), QStringLiteral("1"));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryPictureByHash (const QString &hash)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryPicture"));
    xwriter->writeAttribute(QStringLiteral("hash"), hash);
    //xwriter->writeAttribute(QStringLiteral("base64"), QStringLiteral("1"));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryFavoriteGetByPath (const QString &path,
    const QString &file)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryFavoriteGet"));
    xwriter->writeAttribute(QStringLiteral("path"), path);
    if (!file.isEmpty())
        xwriter->writeAttribute(QStringLiteral("file"), file);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryFavoriteGetByHash (const QString &hash,
    const QString &file)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryFavoriteGet"));
    xwriter->writeAttribute(QStringLiteral("hash"), hash);
    if (!file.isEmpty())
        xwriter->writeAttribute(QStringLiteral("file"), file);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryFavoriteSetByPath (bool favoriteVal,
    const QString &path, const QString &file)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryFavoriteSet"));
    xwriter->writeAttribute(QStringLiteral("path"), path);
    if (!file.isEmpty())
        xwriter->writeAttribute(QStringLiteral("file"), file);
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(favoriteVal));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryFavoriteSetByHash (bool favoriteVal,
    const QString &hash, const QString &file)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryFavoriteSet"));
    xwriter->writeAttribute(QStringLiteral("hash"), hash);
    if (!file.isEmpty())
        xwriter->writeAttribute(QStringLiteral("file"), file);
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(favoriteVal));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::libraryFavoriteSetCurrent (bool favoriteVal)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("LibraryFavoriteSetCurrent"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(favoriteVal));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistAdd (const QString &uri, bool queued,
    bool clear, const QVariantHash &metadata,
    bool startStream, bool freeWheel)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistAdd"));
    if (hasSessionKey)
    {
        try
        {
            Botan::Cipher_Mode_Filter *encryptorFilter =
                new Botan::Cipher_Mode_Filter(
                    Botan::AEAD_Mode::create_or_throw(
                        "ChaCha20Poly1305",
                        BOTAN_DIR_ENCRYPTION));
            Botan::InitializationVector encryptorIV(p->prng, 12);
            encryptorFilter->set_iv(encryptorIV);
            encryptorFilter->set_key(p->sessionKey);

            Botan::Pipe encryptorPipe(
                encryptorFilter,
                new Botan::Base64_Encoder);
            encryptorPipe.process_msg(uri.toStdString());
            xwriter->writeAttribute(
                QStringLiteral("secure_uri"),
                QString::fromStdString(encryptorPipe.read_all_as_string()));
            xwriter->writeAttribute(
                QStringLiteral("nonce"),
                QByteArray(
                    reinterpret_cast<const char *> (encryptorIV.begin()),
                    encryptorIV.size()).toBase64());
        }
        catch (std::exception &x)
        {
            emit error(x.what());
        }
        catch (...)
        {
            emit error(QStringLiteral("failed to send secure message"));
        }
    }
    else
        xwriter->writeAttribute(QStringLiteral("uri"), uri);
    xwriter->writeAttribute(QStringLiteral("queued"),
        QString::number((int) queued));
    xwriter->writeAttribute(QStringLiteral("clear"),
        QString::number((int) clear));
    xwriter->writeAttribute(QStringLiteral("start"),
        QString::number((int) startStream));
    xwriter->writeAttribute(QStringLiteral("freewheel"),
        QString::number((int) freeWheel));
    if (!metadata.isEmpty())
    {
        QVariantHash::const_key_value_iterator iterMeta;

        xwriter->writeStartElement(QStringLiteral("metadata"));
        for (iterMeta = metadata.constKeyValueBegin();
            iterMeta != metadata.constKeyValueEnd();
            iterMeta++)
        {
            xwriter->writeAttribute((*iterMeta).first,
                (*iterMeta).second.toString());
        }
        xwriter->writeEndElement();
    }
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistRemove (int index)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistRemove"));
    xwriter->writeAttribute(QStringLiteral("index"), QString::number(index));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistMoveUp (int index)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistMoveUp"));
    xwriter->writeAttribute(QStringLiteral("index"), QString::number(index));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistMoveDown (int index)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistMoveDown"));
    xwriter->writeAttribute(QStringLiteral("index"), QString::number(index));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistGet (bool picture)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistGet"));
    xwriter->writeAttribute(QStringLiteral("picture"),
        QString::number((int) picture));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistGetSingle (const QString &name)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistGetSingle"));
    xwriter->writeAttribute(QStringLiteral("name"), name);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistGetAll ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("PlaylistGetAll"));
    xwriter->writeEndDocument();
}


void clControlInterface::playlistGetList ()
{
    if (!xwriter)
        return;

    playlistList.clear();
    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("PlaylistGetList"));
    xwriter->writeEndDocument();
}


void clControlInterface::playlistLoad (const QString &name)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistLoad"));
    xwriter->writeAttribute(QStringLiteral("name"), name);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistSave (const QString &name)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistSave"));
    xwriter->writeAttribute(QStringLiteral("name"), name);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistDelete (const QString &name)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistDelete"));
    xwriter->writeAttribute(QStringLiteral("name"), name);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistUpload (const QString &filename,
    const QByteArray &data)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlaylistUpload"));
    xwriter->writeAttribute(QStringLiteral("filename"), filename);
    xwriter->writeCharacters(data);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playlistClear ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("PlaylistClear"));
    xwriter->writeEndDocument();
}


void clControlInterface::matrixListProfiles ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("MatrixListProfiles"));
    xwriter->writeEndDocument();
}


void clControlInterface::matrixGetProfile ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("MatrixGetProfile"));
    xwriter->writeEndDocument();
}


void clControlInterface::matrixSetProfile (const QString &profile)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("MatrixSetProfile"));
    xwriter->writeAttribute(QStringLiteral("value"), profile);
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::selectTrack (int index)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SelectTrack"));
    xwriter->writeAttribute(QStringLiteral("index"), QString::number(index));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::loadRemovable ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("LoadRemovable"));
    xwriter->writeEndDocument();
}


void clControlInterface::play (bool lastTrack)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("Play"));
    xwriter->writeAttribute(QStringLiteral("last"),
        QString::number((int) lastTrack));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::playNextURI (const QString &uri,
    const QVariantHash &metadata,
    bool freeWheel)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("PlayNextURI"));
    if (hasSessionKey)
    {
        try
        {
            Botan::Cipher_Mode_Filter *encryptorFilter =
                new Botan::Cipher_Mode_Filter(
                    Botan::AEAD_Mode::create_or_throw(
                        "ChaCha20Poly1305",
                        BOTAN_DIR_ENCRYPTION));
            Botan::InitializationVector encryptorIV(p->prng, 12);
            encryptorFilter->set_iv(encryptorIV);
            encryptorFilter->set_key(p->sessionKey);

            Botan::Pipe encryptorPipe(
                encryptorFilter,
                new Botan::Base64_Encoder);
            encryptorPipe.process_msg(uri.toStdString());
            xwriter->writeAttribute(
                QStringLiteral("secure_value"),
                QString::fromStdString(encryptorPipe.read_all_as_string()));
            xwriter->writeAttribute(
                QStringLiteral("nonce"),
                QByteArray(
                    reinterpret_cast<const char *> (encryptorIV.begin()),
                    encryptorIV.size()).toBase64());
        }
        catch (std::exception &x)
        {
            emit error(x.what());
        }
        catch (...)
        {
            emit error(QStringLiteral("failed to send secure message"));
        }
    }
    else
        xwriter->writeAttribute(QStringLiteral("value"), uri);
    xwriter->writeAttribute(QStringLiteral("freewheel"),
        QString::number((int) freeWheel));
    if (!metadata.isEmpty())
    {
        QVariantHash::const_key_value_iterator iterMeta;

        xwriter->writeStartElement(QStringLiteral("metadata"));
        for (iterMeta = metadata.constKeyValueBegin();
            iterMeta != metadata.constKeyValueEnd();
            iterMeta++)
        {
            xwriter->writeAttribute((*iterMeta).first,
                (*iterMeta).second.toString());
        }
        xwriter->writeEndElement();
    }
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::pause ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Pause"));
    xwriter->writeEndDocument();
}


void clControlInterface::stop ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Stop"));
    xwriter->writeEndDocument();
}


void clControlInterface::previous ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Previous"));
    xwriter->writeEndDocument();
}


void clControlInterface::next ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Next"));
    xwriter->writeEndDocument();
}


void clControlInterface::backward ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Backward"));
    xwriter->writeEndDocument();
}


void clControlInterface::forward ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("Forward"));
    xwriter->writeEndDocument();
}


void clControlInterface::seek (int position)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("Seek"));
    xwriter->writeAttribute(QStringLiteral("position"), QString::number(position));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::volumeDown ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("VolumeDown"));
    xwriter->writeEndDocument();
}


void clControlInterface::volumeUp ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("VolumeUp"));
    xwriter->writeEndDocument();
}


void clControlInterface::volumeMute ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("VolumeMute"));
    xwriter->writeEndDocument();
}


void clControlInterface::volume (double value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("Volume"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::volumeRange ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement("VolumeRange");
    xwriter->writeEndDocument();
}


void clControlInterface::state ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("State"));
    xwriter->writeEndDocument();
}


void clControlInterface::status (bool subscribe)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("Status"));
    xwriter->writeAttribute(QStringLiteral("subscribe"),
        QString::number((int) subscribe));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setMode (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetMode"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getModes ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetModes"));
    xwriter->writeEndDocument();
}


void clControlInterface::setFilter (int value, int value1x)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetFilter"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    if (value1x >= 0)
        xwriter->writeAttribute(
            QStringLiteral("value1x"), QString::number(value1x));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getFilters ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetFilters"));
    xwriter->writeEndDocument();
}


void clControlInterface::setShaping (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetShaping"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getShapers ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetShapers"));
    xwriter->writeEndDocument();
}


void clControlInterface::setRate (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetRate"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getRates ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetRates"));
    xwriter->writeEndDocument();
}


void clControlInterface::setJunkFilter (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetJunkFilter"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number((int) value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getJunkFilters ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetJunkFilters"));
    xwriter->writeEndDocument();
}


void clControlInterface::setInvert (bool value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetInvert"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number((int) value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setAdaptive (bool value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetAdaptiveVolume"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number((int) value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setConvolution (bool value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetConvolution"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number((int) value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setRepeat (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetRepeat"));
    xwriter->writeAttribute(QStringLiteral("value"), QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setRandom (bool value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetRandom"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number((int) value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setDisplay (int value)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetDisplay"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(value));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getDisplay ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetDisplay"));
    xwriter->writeEndDocument();
}


void clControlInterface::getTransport ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetTransport"));
    xwriter->writeEndDocument();
}


void clControlInterface::setTransport (int value, const QString &arg,
    bool freeWheel)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetTransport"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(value));
    xwriter->writeAttribute(QStringLiteral("arg"), arg);
    xwriter->writeAttribute(QStringLiteral("freewheel"),
        QString::number((int) freeWheel));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setTransportPath (const QString &path,
    bool freeWheel)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetTransportPath"));
    xwriter->writeAttribute(QStringLiteral("value"), path);
    xwriter->writeAttribute(QStringLiteral("freewheel"),
        QString::number((int) freeWheel));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::setTransportRate (unsigned newRate)
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeStartElement(QStringLiteral("SetTransportRate"));
    xwriter->writeAttribute(QStringLiteral("value"),
        QString::number(newRate));
    xwriter->writeEndElement();
    xwriter->writeEndDocument();
}


void clControlInterface::getInputs ()
{
    if (!xwriter)
        return;

    xwriter->writeStartDocument();
    xwriter->writeEmptyElement(QStringLiteral("GetInputs"));
    xwriter->writeEndDocument();
}


void clControlInterface::setMetering (bool enabled)
{
    emit enableMetering(enabled);
}


bool clControlInterface::getMetering ()
{
    return meterInterface->getMetering();
}


void clControlInterface::onDiscoReadyRead ()
{
    while (discoSocket->hasPendingDatagrams())
    {
        QNetworkDatagram discoResponse = discoSocket->receiveDatagram();
        QHostAddress senderAddress = discoResponse.senderAddress();
        QXmlStreamReader xmlResponse(discoResponse.data());

        QString friendlyName;
        QString software;
        QXmlStreamReader::TokenType tt;

        do {
            tt = xmlResponse.readNext();

            if (tt == QXmlStreamReader::StartElement)
            {
#               if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
                if (xmlResponse.name() == "discover")
#               else
                if (xmlResponse.name() == QStringLiteral("discover"))
#               endif
                {
#                   if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
                    if (xmlResponse.attributes().value("result") != "OK")
                        return;
#                   else
                    if (xmlResponse.attributes().value("result") !=
                        QStringLiteral("OK"))
                        return;
#                   endif
                    friendlyName =
                        xmlResponse.attributes().value("name").toString();
                    software =
                        xmlResponse.attributes().value("version").toString();
                }
            }
            else if (tt == QXmlStreamReader::Characters)
            {
#               if (QT_VERSION < QT_VERSION_CHECK(6, 0, 0))
                if (xmlResponse.text() != "hqplayer")
#               else
                if (xmlResponse.text() != QStringLiteral("hqplayer"))
#               endif
                {
                    qDebug("wrong content in discovery message '%s'",
                        xmlResponse.text().toUtf8().constData());
                    return;
                }
            }
            else if (tt == QXmlStreamReader::NoToken)
            {
                qDebug("empty discovery response!");
                return;
            }
            else if (tt == QXmlStreamReader::Invalid)
            {
                qDebug("invalid discovery response: %s",
                    xmlResponse.errorString().toUtf8().constData());
                return;
            }
        } while (tt != QXmlStreamReader::EndDocument);

        emit hostDiscovered(senderAddress.toString(), friendlyName, software);
    }
}


void clControlInterface::onConnected ()
{
    csocket->setSocketOption(QAbstractSocket::KeepAliveOption, 1);
    csocket->setSocketOption(QAbstractSocket::TypeOfServiceOption, 32);
#   ifndef _WIN32
    int option;
    int sdescriptor = csocket->socketDescriptor();
    option = 3;
    if (setsockopt(sdescriptor, IPPROTO_TCP, TCP_KEEPCNT,
                   &option, sizeof(option)) != 0)
        qDebug("setsockopt(, IPPROTO_TCP, TCP_KEEPCNT,,) failed");
    option = 10;
    if (setsockopt(sdescriptor, IPPROTO_TCP, TCP_KEEPINTVL,
                   &option, sizeof(option)) != 0)
        qDebug("setsockopt(, IPPROTO_TCP, TCP_KEEPINTVL,,) failed");
#   endif  // _WIN32

    if (xreader) delete xreader;
    xreader = new QXmlStreamReader;
    if (xwriter) delete xwriter;
    xwriter = new QXmlStreamWriter(csocket);
    emit connected();
}


void clControlInterface::onDisconnected ()
{
    emit disconnected();
    hasSessionKey = false;
    if (xreader)
    {
        delete xreader;
        xreader = 0;
    }
    if (xwriter)
    {
        delete xwriter;
        xwriter = 0;
    }
}


void clControlInterface::onError (QAbstractSocket::SocketError socketError)
{
    Q_UNUSED(socketError);

    emit error(csocket->errorString());
}


void clControlInterface::onReadyRead ()
{
    recvBuffer.append(csocket->readAll());

    if (pictureSize)
    {
        if (recvBuffer.size() < pictureSize)
            return;

        pictureData.append(recvBuffer.constData(), pictureSize);
        if (recvBuffer.size() > pictureSize)
            recvBuffer.remove(0, pictureSize);
        else
            recvBuffer.clear();

        emit libraryPicture(pictureMime, pictureData);
        pictureSize = 0;
        pictureMime.clear();
        pictureData.clear();
        emit endOfData();

        return;
    }

    while (recvBuffer.count('\n') > 0)
    {
        int i = recvBuffer.indexOf('\n') + 1;
        QByteArray line = recvBuffer.left(i);
        if (recvBuffer.size() > i)
            recvBuffer.remove(0, i);
        else
            recvBuffer.clear();
        //qDebug("response:\n\t%s", line.constData());
        xreader->addData(QString::fromUtf8(line));

        while (true)
        {
            QXmlStreamReader::TokenType tt = xreader->readNext();
            if (tt == QXmlStreamReader::StartElement)
            {
                QString parentElement =
                    parentStack.isEmpty() ? QString() : parentStack.top();
                QString cmd = xreader->name().toString();

                // most used two operations first
                if (cmd == "State")
                {
                    int iFilter1x = -1;
                    int iFilterNx = -1;

                    if (xreader->attributes().hasAttribute("filter1x"))
                        iFilter1x = xreader->attributes().value("filter1x").toInt();
                    if (xreader->attributes().hasAttribute("filterNx"))
                        iFilterNx = xreader->attributes().value("filterNx").toInt();
                    emit stateResponse(
                        xreader->attributes().value("state").toString().toInt(),
                        xreader->attributes().value("mode").toString().toInt(),
                        xreader->attributes().value("filter").toString().toInt(),
                        iFilter1x, iFilterNx,
                        xreader->attributes().value("shaper").toString().toInt(),
                        xreader->attributes().value("rate").toString().toInt(),
                        xreader->attributes().value("volume").toString().toDouble(),
                        xreader->attributes().value("active_mode").toString().toUInt(),
                        xreader->attributes().value("active_rate").toString().toUInt(),
                        xreader->attributes().value("invert").toString().toUInt(),
                        xreader->attributes().value("convolution").toString().toUInt(),
                        xreader->attributes().value("repeat").toString().toInt(),
                        xreader->attributes().value("random").toString().toUInt(),
                        xreader->attributes().value("adaptive").toString().toUInt(),
                        xreader->attributes().value("filter_junk").toString().toInt(),
                        xreader->attributes().value("matrix_profile").toString());
                }
                else if (cmd == "Status")
                {
                    emit statusResponse(
                        xreader->attributes().value("state").toString().toInt(),
                        xreader->attributes().value("track").toString().toUInt(),
                        xreader->attributes().value("track_id").toString(),
                        xreader->attributes().value("min").toString().toInt(),
                        xreader->attributes().value("sec").toString().toInt(),
                        xreader->attributes().value("volume").toString().toDouble(),
                        xreader->attributes().value("clips").toString().toUInt(),
                        xreader->attributes().value("tracks_total").toString().toUInt(),
                        xreader->attributes().value("track_serial").toString().toUInt(),
                        xreader->attributes().value("transport_serial").toString().toUInt(),
                        xreader->attributes().value("queued").toString().toUInt(),
                        xreader->attributes().value("position").toString().toDouble(),
                        xreader->attributes().value("length").toString().toDouble(),
                        xreader->attributes().value("begin_min").toString().toInt(),
                        xreader->attributes().value("begin_sec").toString().toInt(),
                        xreader->attributes().value("remain_min").toString().toInt(),
                        xreader->attributes().value("remain_sec").toString().toInt(),
                        xreader->attributes().value("total_min").toString().toInt(),
                        xreader->attributes().value("total_sec").toString().toInt(),
                        xreader->attributes().value("output_delay").toString().toLong(),
                        xreader->attributes().value("apod").toString().toUInt());
                    emit statusInfo(
                        xreader->attributes().value("active_mode").toString(),
                        xreader->attributes().value("active_filter").toString(),
                        xreader->attributes().value("active_shaper").toString(),
                        xreader->attributes().value("active_rate").toString().toUInt(),
                        xreader->attributes().value("active_bits").toString().toUInt(),
                        xreader->attributes().value("active_channels").toString().toUInt(),
                        xreader->attributes().value("filter_junk").toString().toInt(),
                        xreader->attributes().value("correction").toString().toUInt(),
                        xreader->attributes().value("random").toString().toUInt(),
                        xreader->attributes().value("repeat").toString().toInt());
                    emit statusIO(
                        xreader->attributes().value("input_fill").toString().toFloat(),
                        xreader->attributes().value("output_fill").toString().toFloat(),
                        xreader->attributes().value("process_speed").toString().toFloat());
                }
                else if (cmd == "SessionAuthentication")
                {
                    completeAuthentication();
                }
                else if (cmd == "GetInfo")
                {
                    emit info(
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("product").toString(),
                        xreader->attributes().value("version").toString(),
                        xreader->attributes().value("platform").toString(),
                        xreader->attributes().value("engine").toString());
                }
                else if (cmd == "GetLicense")
                {
                    emit license(
                        xreader->attributes().value("valid").toString().toUInt(),
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("fingerprint").toString());
                }
                else if (cmd == "ConfigurationList")
                {
                    activeCfg =
                        xreader->attributes().value("active").toString();
                }
                else if (cmd == "ConfigurationItem")
                {
                    emit configurationItem(
                        xreader->attributes().value("name").toString());
                }
                else if (cmd == "ConfigurationGet")
                {
                    emit configurationActive(
                        xreader->attributes().value("value").toString());
                }
                else if (cmd == "LibraryGetHash")
                {
                    emit libraryHash(
                        xreader->attributes().value("value").toString());
                }
                else if (cmd == "LibraryGet")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "LibraryDirectory")
                {
                    QVariantHash hashAnalysis;
                    hashAnalysis["peak"] = float(
                        xreader->attributes().value("peak").toInt() / 1000.0);
                    hashAnalysis["rms"] = float(
                        xreader->attributes().value("rms").toInt() / 1000.0);
                    hashAnalysis["lufs"] = float(
                        xreader->attributes().value("lufs").toInt() / 1000.0);
                    hashAnalysis["lulr"] = float(
                        xreader->attributes().value("lulr").toInt() / 1000.0);
                    hashAnalysis["apod"] =
                        xreader->attributes().value("apod").toUInt();

                    emit libraryDirectory(
                        xreader->attributes().value("path").toString(),
                        xreader->attributes().value("hash").toString(),
                        xreader->attributes().value("rate").toString().toUInt(),
                        xreader->attributes().value("bits").toString().toUInt(),
                        xreader->attributes().value("channels").toString().toUInt(),
                        xreader->attributes().value("bitrate").toString().toUInt(),
                        fromEscaped(xreader->attributes().value("artist").toString()),
                        fromEscaped(xreader->attributes().value("composer").toString()),
                        fromEscaped(xreader->attributes().value("performer").toString()),
                        fromEscaped(xreader->attributes().value("album").toString()),
                        fromEscaped(xreader->attributes().value("genre").toString()),
                        fromEscaped(xreader->attributes().value("date").toString()),
                        fromEscaped(xreader->attributes().value("cover").toString()),
                        fromEscaped(xreader->attributes().value("booklet").toString()),
                        xreader->attributes().value("favorite").toInt(),
                        hashAnalysis);

                    QByteArray coverStr(
                        xreader->attributes().value("picture").toUtf8());
                    if (!coverStr.isEmpty())
                        emit libraryPicture(
                            QString(), QByteArray::fromBase64(coverStr));
                }
                else if (cmd == "LibraryFile")
                {
                    QVariantHash hashAnalysis;
                    hashAnalysis["peak"] = float(
                        xreader->attributes().value("peak").toInt() / 1000.0);
                    hashAnalysis["rms"] = float(
                        xreader->attributes().value("rms").toInt() / 1000.0);
                    hashAnalysis["lufs"] = float(
                        xreader->attributes().value("lufs").toInt() / 1000.0);
                    hashAnalysis["lulr"] = float(
                        xreader->attributes().value("lulr").toInt() / 1000.0);
                    hashAnalysis["apod"] =
                        xreader->attributes().value("apod").toUInt();

                    emit libraryFile(
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("hash").toString(),
                        fromEscaped(xreader->attributes().value("song").toString()),
                        fromEscaped(xreader->attributes().value("artist").toString()),
                        fromEscaped(xreader->attributes().value("composer").toString()),
                        fromEscaped(xreader->attributes().value("performer").toString()),
                        fromEscaped(xreader->attributes().value("genre").toString()),
                        fromEscaped(xreader->attributes().value("date").toString()),
                        xreader->attributes().value("length").toString().toDouble(),
                        xreader->attributes().value("number").toString().toUInt(),
                        fromEscaped(xreader->attributes().value("cover").toString()),
                        xreader->attributes().value("favorite").toInt(),
                        hashAnalysis);

                    QByteArray coverStr(
                        xreader->attributes().value("picture").toUtf8());
                    if (!coverStr.isEmpty())
                        emit libraryPicture(
                            QString(), QByteArray::fromBase64(coverStr));
                }
                else if (cmd == "LibraryPicture")
                {
                    pictureSize =
                        xreader->attributes().value("size").toString().toInt();
                    if (pictureSize > 0)
                    {
                        pictureMime =
                            xreader->attributes().value("type").toString();
                        pictureData.reserve(pictureSize);
                        // reset the XML parser and fetch the data on next cycle
                        xreader->clear();
                        return;
                    }
                    else
                        emit libraryPicture(QString(), QByteArray());
                }
                else if (cmd == "LibraryFavoriteGet" ||
                    cmd == "LibraryFavoriteSet" ||
                    cmd == "LibraryFavoriteSetCurrent")
                {
                    QString pathHash;

                    pathHash = xreader->attributes().value("hash").toString();
                    if (pathHash.isEmpty())
                        pathHash = xreader->attributes().value("path").toString();
                    emit favorite(
                        pathHash,
                        xreader->attributes().value("file").toString(),
                        xreader->attributes().value("uri").toString(),
                        xreader->attributes().value("value").toInt());
                }
                else if (cmd == "PlaylistGet")
                {
                    isAlbum =
                        xreader->attributes().value("album").toInt() ?
                            true : false;
                }
                else if (cmd == "PlaylistItem")
                {
                    QString uri =
                        xreader->attributes().value("secure_uri").toString();
                    if (!uri.isEmpty() && hasSessionKey)
                    {
                        QByteArray cipherNonce(
                            QByteArray::fromBase64(
                                xreader->attributes().value("nonce").toLatin1()));
                        Botan::Cipher_Mode_Filter *decryptorFilter =
                            new Botan::Cipher_Mode_Filter(
                                Botan::AEAD_Mode::create_or_throw(
                                    "ChaCha20Poly1305",
                                    BOTAN_DIR_DECRYPTION));
                        decryptorFilter->set_iv(Botan::InitializationVector(
                            reinterpret_cast<uint8_t *> (cipherNonce.data()),
                            cipherNonce.size()));
                        decryptorFilter->set_key(Botan::SymmetricKey(
                            p->sessionKey));

                        Botan::Pipe decryptorPipe(
                            new Botan::Base64_Decoder,
                            decryptorFilter);
                        decryptorPipe.process_msg(uri.toStdString());
                        uri = QString::fromStdString(
                            decryptorPipe.read_all_as_string());
                    }
                    else
                        uri = xreader->attributes().value("uri").toString();
                    emit playlistItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("rate").toString().toUInt(),
                        xreader->attributes().value("bits").toString().toUInt(),
                        xreader->attributes().value("channels").toString().toUInt(),
                        xreader->attributes().value("bitrate").toString().toUInt(),
                        uri,
                        xreader->attributes().value("mime").toString(),
                        fromEscaped(xreader->attributes().value("artist").toString()),
                        fromEscaped(xreader->attributes().value("composer").toString()),
                        fromEscaped(xreader->attributes().value("performer").toString()),
                        fromEscaped(xreader->attributes().value("album").toString()),
                        fromEscaped(xreader->attributes().value("song").toString()),
                        xreader->attributes().value("length").toString().toDouble(),
                        fromEscaped(xreader->attributes().value("cover").toString()),
                        QByteArray::fromBase64(
                            xreader->attributes().value("picture").toUtf8()));
                }
                else if (parentElement == "PlaylistGetList" &&
                    cmd == "Playlist")
                {
                    playlistList.append(
                        xreader->attributes().value("name").toString());
                }
                else if ((parentElement == "PlaylistGetSingle" ||
                    parentElement == "PlaylistGetAll") && cmd == "Playlist")
                {
                    emit playlistBegin(xreader->attributes().value("name").toString());
                }
                else if (parentElement == "Playlist" && cmd == "track")
                {
                    emit playlistEntry(
                        xreader->attributes().value("type").toString(),
                        xreader->attributes().value("uri").toString(),
                        xreader->attributes().value("mime_type").toString(),
                        xreader->attributes().value("cover").toString(),
                        xreader->attributes().value("length").toString().toDouble(),
                        xreader->attributes().value("frames").toString().toULongLong(),
                        xreader->attributes().value("float").toString().toUInt(),
                        xreader->attributes().value("sdm").toString().toUInt(),
                        xreader->attributes().value("rate").toString().toUInt(),
                        xreader->attributes().value("bits").toString().toUInt(),
                        xreader->attributes().value("channels").toString().toUInt(),
                        xreader->attributes().value("bitrate").toString().toUInt(),
                        xreader->attributes().value("track_gain").toString().toDouble(),
                        xreader->attributes().value("album_gain").toString().toDouble(),
                        fromEscaped(xreader->attributes().value("artist").toString()),
                        fromEscaped(xreader->attributes().value("composer").toString()),
                        fromEscaped(xreader->attributes().value("performer").toString()),
                        fromEscaped(xreader->attributes().value("album_artist").toString()),
                        fromEscaped(xreader->attributes().value("album").toString()),
                        fromEscaped(xreader->attributes().value("song").toString()),
                        fromEscaped(xreader->attributes().value("genre").toString()),
                        fromEscaped(xreader->attributes().value("date").toString()));
                }
                else if (cmd == "MatrixProfile")
                {
                    emit matrixProfileItem(
                        xreader->attributes().value("name").toString());
                }
                else if (cmd == "MatrixGetProfile")
                {
                    emit matrixProfile(
                        xreader->attributes().value("value").toString());
                }
                else if (cmd == "GetModes")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "ModesItem")
                {
                    emit modesItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("value").toString().toInt());
                }
                else if (cmd == "GetFilters")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "FiltersItem")
                {
                    emit filtersItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("value").toString().toInt(),
                        xreader->attributes().value("arg").toString().toUInt(),
                        xreader->attributes().value("description").toString());
                }
                else if (cmd == "GetShapers")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "ShapersItem")
                {
                    emit shapersItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("value").toString().toInt());
                }
                else if (cmd == "GetRates")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "RatesItem")
                {
                    emit ratesItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("rate").toString().toUInt());
                }
                else if (cmd == "GetJunkFilters")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "JunkFiltersItem")
                {
                    emit junkFiltersItem(
                        xreader->attributes().value("index").toString().toUInt(),
                        xreader->attributes().value("name").toString(),
                        xreader->attributes().value("value").toString().toInt());
                }
                else if (cmd == "VolumeRange")
                {
                    emit volumeRangeResponse(
                        xreader->attributes().value("min").toString().toDouble(),
                        xreader->attributes().value("max").toString().toDouble(),
                        xreader->attributes().value("enabled").toString().toInt() ?
                            true : false,
                        xreader->attributes().value("adaptive").toString().toInt() ?
                            true : false);
                }
                else if (cmd == "GetDisplay")
                {
                    emit displayResponse(
                        xreader->attributes().value("value").toString().toInt());
                }
                else if (cmd == "GetTransport")
                {
                    emit transportResponse(
                        xreader->attributes().value("value").toString().toInt(),
                        xreader->attributes().value("arg").toString());
                }
                else if (cmd == "GetInputs")
                {
                    // ignore upper section and wait for items
                }
                else if (cmd == "InputsItem")
                {
                    emit inputsItem(
                        xreader->attributes().value("name").toString());
                }
                else
                {
                    lastResult =
                        xreader->attributes().value("result").toString();
                    if (lastResult == "Error")
                        emit response(cmd, xreader->text().toString());
                    else if (lastResult == "OK")
                        emit response(cmd, QString());
                }

                // handle special sub-elements
                if (parentElement == "Status" && cmd == "metadata")
                {
                    QVariantHash hashMetadata;

                    QString uri =
                        xreader->attributes().value("secure_uri").toString();
                    if (!uri.isEmpty() && hasSessionKey)
                    {
                        QByteArray cipherNonce(
                            QByteArray::fromBase64(
                                xreader->attributes().value("nonce").toLatin1()));
                        Botan::Cipher_Mode_Filter *decryptorFilter =
                            new Botan::Cipher_Mode_Filter(
                                Botan::AEAD_Mode::create_or_throw(
                                    "ChaCha20Poly1305",
                                    BOTAN_DIR_DECRYPTION));
                        decryptorFilter->set_iv(Botan::InitializationVector(
                            reinterpret_cast<uint8_t *> (cipherNonce.data()),
                            cipherNonce.size()));
                        decryptorFilter->set_key(Botan::SymmetricKey(
                            p->sessionKey));

                        Botan::Pipe decryptorPipe(
                            new Botan::Base64_Decoder,
                            decryptorFilter);
                        decryptorPipe.process_msg(uri.toStdString());
                        uri = QString::fromStdString(
                            decryptorPipe.read_all_as_string());
                    }
                    else
                        uri = xreader->attributes().value("uri").toString();
                    hashMetadata["uri"] = uri;

                    hashMetadata["mime"] =
                        xreader->attributes().value("mime").toString();
                    hashMetadata["artist"] =
                        xreader->attributes().value("artist").toString();
                    hashMetadata["composer"] =
                        xreader->attributes().value("composer").toString();
                    hashMetadata["performer"] =
                        xreader->attributes().value("performer").toString();
                    hashMetadata["album"] =
                        xreader->attributes().value("album").toString();
                    hashMetadata["song"] =
                        xreader->attributes().value("song").toString();
                    hashMetadata["genre"] =
                        xreader->attributes().value("genre").toString();
                    hashMetadata["date"] =
                        xreader->attributes().value("date").toString();
                    hashMetadata["albumartist"] =
                        xreader->attributes().value("albumartist").toString();
                    hashMetadata["track_id"] =
                        xreader->attributes().value("track_id").toString();
                    // format
                    hashMetadata["samplerate"] =
                        xreader->attributes().value("samplerate").toUInt();
                    hashMetadata["bits"] =
                        xreader->attributes().value("bits").toUInt();
                    hashMetadata["channels"] =
                        xreader->attributes().value("channels").toUInt();
                    hashMetadata["float"] =
                        bool(xreader->attributes().value("float").toUInt());
                    hashMetadata["sdm"] =
                        bool(xreader->attributes().value("sdm").toUInt());
                    hashMetadata["bitrate"] =
                        xreader->attributes().value("bitrate").toUInt();
                    hashMetadata["features"] =
                        xreader->attributes().value("features").toULongLong();
                    hashMetadata["extrainfo"] =
                        xreader->attributes().value("extrainfo").toULongLong();
                    hashMetadata["gain"] =
                        xreader->attributes().value("gain").toDouble();

                    emit statusMetadata(hashMetadata);
                }

                parentStack.push(xreader->name().toString());
            }
            else if (tt == QXmlStreamReader::EndElement)
            {
                if (!parentStack.isEmpty())
                    parentStack.pop();
                /*QString parentElement =
                    parentStack.isEmpty() ? QString() : parentStack.top();*/
                QString cmd = xreader->name().toString();

                if (cmd == "ConfigurationList")
                    emit configurationEnd(activeCfg);
                else if (cmd == "LibraryDirectory")
                    emit libraryDirectoryEnd();
                else if (cmd == "LibraryGet")
                    emit libraryEnd();
                else if (cmd == "PlaylistGet")
                    emit playlistEnd(isAlbum);
                // NOTE: order here is important
                else if (cmd == "PlaylistGetList")
                    emit playlists(playlistList);
                else if (cmd == "Playlist")
                    emit playlistEnd();
                else if (cmd == "MatrixListProfiles")
                    emit matrixProfileEnd();
                else if (cmd == "Play" || cmd == "SelectTrack")
                {
                    if (lastResult == "OK")
                        emit playComplete();
                }
                else if (cmd == "Stop")
                {
                    if (lastResult == "OK")
                        emit stopComplete();
                }
                else if (cmd == "GetModes")
                    emit modesEnd();
                else if (cmd == "GetFilters")
                    emit filtersEnd();
                else if (cmd == "GetShapers")
                    emit shapersEnd();
                else if (cmd == "GetRates")
                    emit ratesEnd();
                else if (cmd == "GetJunkFilters")
                    emit junkFiltersEnd();
                else if (cmd == "GetInputs")
                    emit inputsEnd();
            }
            else if (tt == QXmlStreamReader::EndDocument)
            {
                xreader->clear();
                emit endOfResponse();
                break;
            }
            else if (tt == QXmlStreamReader::Invalid)
            {
                if (xreader->error() !=
                    QXmlStreamReader::PrematureEndOfDocumentError)
                {
                    emit error(xreader->errorString());
                    xreader->clear();
                    break;
                }
                else break;  // continue fetching more data
            }
            else if (tt == QXmlStreamReader::NoToken)
                break;
        }
    }
}


QString clControlInterface::fromEscaped (const QString &src)
{
    QString dst(src);

    return dst.replace("&lt;", "<").replace("&gt;", ">").replace("&amp;", "&").replace("&quot;", "\"").replace("&apos;", "\'");
}

