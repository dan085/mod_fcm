# mod_fcm


mod_fcm is an ejabberd module to send offline messages as PUSH notifications for Android using Google Cloud Messaging 



   mod_fcm is an ejabberd module to send offline messages as PUSH notifications for Android using Google Cloud Messaging API.

   Consider using mod_push which implements XEP-0357 and works with many PUSH services.

   This module has nothing to do with XEP-0357.

   The main goal of this module is to send all offline messages to the registered (see Usage) clients via Google Cloud Messaging service.


   Compilation:

   Because of the dependencies such as xml.hrl, logger.hrl, etc it's recommended to compile the module with ejabberd itself: put it in the ejabberd/src directory and run the default compiler.

   Configuration:

   To let the module work fine with Google APIs, put the lines below in the ejabberd modules section:


    mod_fcm:
        fcm_api_key: "Your Google APIs key"


    <iq to="YourServer" type="set">
      <register xmlns="https://fcm.googleapis.com/fcm" >
        <key>API_KEY</key>
      </register>
    </iq>


   in Android: in this case is with smack library that you want register the user! is importan to enable offline messages in  ejabberd.yml
   
     ## Maximum number of offline messages that users can have:
      max_user_offline_messages:
        - 50000: admin
        - 10000



     public int register_user_mod_push(final String num_register_fcm) throws UnsupportedEncodingException {
            final IQ iq = new IQ("register", "https://fcm.googleapis.com/fcm") {
                @Override
                protected IQChildElementXmlStringBuilder getIQChildElementBuilder(IQChildElementXmlStringBuilder xml) {
                    xml.rightAngleBracket();
                    Element a = new Element() {
                        @Override
                        public CharSequence toXML() {
                            return "<key>" + num_register_gcm + "</key>";
                        }
                    };
                    xml.element(a);
                    return xml;
                }
            };
            iq.setType(IQ.Type.set);
            iq.setTo("biimbak.com");
            try {
                connection.sendStanza(iq);
                return 1;
            } catch (SmackException.NotConnectedException e) {
                e.printStackTrace();
                logout();
                return 0;
            }
        }


